import Foundation

/// What the Mac already does with a shortcut. Pure: the caller passes in what
/// it read from the system (symbolic hot keys, the 🌐/fn key setting).
public struct ShortcutIssue: Equatable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
        case note, warning, conflict, blocked
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    /// Where the user can fix it.
    public enum Fix: Equatable, Sendable {
        case keyboardShortcuts   // System Settings › Keyboard › Keyboard Shortcuts…
        case globeKey            // System Settings › Keyboard › "Press 🌐 key to"
    }

    public let severity: Severity
    public let message: String
    public let fix: Fix?

    public init(_ severity: Severity, _ message: String, fix: Fix? = nil) {
        self.severity = severity
        self.message = message
        self.fix = fix
    }
}

/// One enabled entry from com.apple.symbolichotkeys.
public struct SystemHotKey: Equatable, Sendable {
    public let id: Int
    public let keyCode: Int
    public let mask: Int   // symbolic-hot-key modifier mask

    public init(id: Int, keyCode: Int, mask: Int) {
        self.id = id
        self.keyCode = keyCode
        self.mask = mask
    }

    /// Names for the ids people are most likely to hit.
    public var name: String {
        switch id {
        case 7...26: "a keyboard navigation shortcut"
        case 27: "Move focus to next window"
        case 28: "Save picture of screen as a file"
        case 29: "Copy picture of screen to the clipboard"
        case 30: "Save picture of selected area as a file"
        case 31: "Copy picture of selected area to the clipboard"
        case 32, 34: "Mission Control"
        case 33, 35: "Application windows"
        case 36, 37: "Show Desktop"
        case 52: "Turn Dock hiding on/off"
        case 60: "Select the previous input source"
        case 61: "Select next source in Input menu"
        case 64: "Show Spotlight search"
        case 65: "Show Finder search window"
        case 79, 80: "Move left a space"
        case 81, 82: "Move right a space"
        case 118...133: "Switch to a Desktop"
        case 160: "Show Launchpad"
        case 163: "Show Notification Center"
        case 175: "Turn Do Not Disturb on/off"
        case 184: "Screenshot and recording options"
        default: "a macOS keyboard shortcut"
        }
    }
}

public enum ShortcutCheck {
    /// "Press 🌐 key to" (com.apple.HIToolbox AppleFnUsageType).
    public enum GlobeKeyAction: Int, Sendable {
        case nothing = 0, changeInputSource = 1, emoji = 2, dictation = 3

        var label: String {
            switch self {
            case .nothing: "do nothing"
            case .changeInputSource: "change the input source"
            case .emoji: "show the emoji picker"
            case .dictation: "start macOS dictation"
            }
        }
    }

    /// Common shortcuts nearly every app uses, as (key, generic modifiers).
    static let appShortcuts: [(UInt16, Modifiers, String)] = [
        (8, .command, "Copy"), (9, .command, "Paste"), (7, .command, "Cut"), (6, .command, "Undo"),
        (0, .command, "Select All"), (1, .command, "Save"), (12, .command, "Quit"),
        (13, .command, "Close Window"), (17, .command, "New Tab"), (45, .command, "New Window"),
        (31, .command, "Open"), (35, .command, "Print"), (3, .command, "Find"), (4, .command, "Hide"),
        (46, .command, "Minimize"), (43, .command, "Settings"), (48, .command, "app switcher"),
        (6, [.command, .shift], "Redo"), (50, .command, "Cycle windows"),
    ]

    public static func issues(for s: Shortcut, systemHotKeys: [SystemHotKey], globeKey: GlobeKeyAction) -> [ShortcutIssue] {
        var out: [ShortcutIssue] = []
        let mods = s.modifiers

        if let key = s.keyCode {
            let generic = mods.generic
            let typingMods = generic.subtracting(.shift).isEmpty
            let isFunction = KeyNames.functionKeys.contains(key)
            if key == KeyNames.escape {
                out.append(.init(.blocked, "Esc finishes a dictation, so it can't start one."))
            } else if typingMods && !isFunction && !KeyNames.navigationKeys.contains(key) {
                out.append(.init(.blocked, "\(KeyNames.name(key)) is used for typing. Add Control, Option or Command."))
            } else if typingMods && KeyNames.navigationKeys.contains(key) {
                out.append(.init(.blocked, "\(KeyNames.name(key)) moves the cursor while typing. Add Control, Option or Command."))
            }
            for (code, m, name) in appShortcuts where code == key && m == generic {
                out.append(.init(.conflict, "Most apps use \(s.displayName) for \(name)."))
            }
            for hk in systemHotKeys where hk.keyCode == Int(key) && hk.mask & 0x1E_0000 == mods.symbolicHotKeyMask {
                out.append(.init(.conflict, "macOS uses this for “\(hk.name)”. Turn that off or change it in Keyboard Shortcuts.", fix: .keyboardShortcuts))
            }
            if isFunction && mods.isEmpty {
                out.append(.init(.warning, "On Mac keyboards the top row usually controls brightness and volume; \(KeyNames.name(key)) only arrives when you also hold fn, unless “Use F1, F2, etc. keys as standard function keys” is on.", fix: .keyboardShortcuts))
            }
        } else {
            // Modifiers alone.
            if mods.isEmpty {
                out.append(.init(.blocked, "Press at least one key."))
            } else if mods.count == 1 && !mods.intersection(.shift).isEmpty {
                out.append(.init(.blocked, "Shift alone is used for every capital letter."))
            } else if mods.count == 1 && !mods.intersection([.leftCommand, .leftControl, .leftOption]).isEmpty {
                out.append(.init(.warning, "You use \(s.displayName) in other shortcuts all the time; the indicator will flash briefly each time. A right-hand key is easier."))
            }
            if mods.contains(.fn) && globeKey != .nothing {
                if mods == .fn {
                    out.append(.init(.conflict, "The 🌐/fn key is set to \(globeKey.label). Set “Press 🌐 key to” to “Do Nothing”.", fix: .globeKey))
                } else {
                    out.append(.init(.note, "The 🌐/fn key is set to \(globeKey.label); Loquor stops that from happening when you use this shortcut."))
                }
            }
            if mods.count == 1 && !mods.intersection(.option).isEmpty {
                out.append(.init(.note, "Option + a letter still types special characters; only pressing it on its own starts dictation."))
            }
        }
        return out.sorted { $0.severity > $1.severity }
    }
}
