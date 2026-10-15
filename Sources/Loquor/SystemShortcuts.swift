import AppKit
import LoquorCore

/// Reads what macOS itself does with keys, for ShortcutCheck.
enum SystemShortcuts {
    /// macOS's built-in shortcuts as (id, key code, mask). The preferences file
    /// only lists entries someone changed, so these are assumed on unless it
    /// says otherwise.
    private static let defaults: [SystemHotKey] = [
        .init(id: 27, keyCode: 50, mask: 0x10_0000),   // ⌘`
        .init(id: 28, keyCode: 20, mask: 0x12_0000),   // ⇧⌘3
        .init(id: 29, keyCode: 20, mask: 0x16_0000),   // ⌃⇧⌘3
        .init(id: 30, keyCode: 21, mask: 0x12_0000),   // ⇧⌘4
        .init(id: 31, keyCode: 21, mask: 0x16_0000),   // ⌃⇧⌘4
        .init(id: 32, keyCode: 126, mask: 0x84_0000),  // ⌃↑
        .init(id: 33, keyCode: 125, mask: 0x84_0000),  // ⌃↓
        .init(id: 36, keyCode: 103, mask: 0x80_0000),  // F11
        .init(id: 52, keyCode: 2, mask: 0x18_0000),    // ⌥⌘D
        .init(id: 60, keyCode: 49, mask: 0x04_0000),   // ⌃Space
        .init(id: 61, keyCode: 49, mask: 0x0C_0000),   // ⌃⌥Space
        .init(id: 64, keyCode: 49, mask: 0x10_0000),   // ⌘Space
        .init(id: 65, keyCode: 49, mask: 0x18_0000),   // ⌥⌘Space
        .init(id: 79, keyCode: 123, mask: 0x84_0000),  // ⌃←
        .init(id: 81, keyCode: 124, mask: 0x84_0000),  // ⌃→
        .init(id: 184, keyCode: 23, mask: 0x12_0000),  // ⇧⌘5
    ]

    /// Enabled system shortcuts: the defaults, overridden by the user's changes.
    static func hotKeys() -> [SystemHotKey] {
        let saved = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                              "com.apple.symbolichotkeys" as CFString) as? [String: Any] ?? [:]
        var byID = Dictionary(uniqueKeysWithValues: defaults.map { ($0.id, $0) })
        for (key, entry) in saved {
            guard let id = Int(key), let entry = entry as? [String: Any] else { continue }
            let enabled = (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) == 1)
            let params = (entry["value"] as? [String: Any])?["parameters"] as? [Int]
            if !enabled {
                byID[id] = nil
            } else if let params, params.count == 3, params[1] != 65535 {
                byID[id] = SystemHotKey(id: id, keyCode: params[1], mask: params[2])
            }
        }
        return Array(byID.values)
    }

    /// "Press 🌐 key to". Not set means the macOS default, the emoji picker.
    static func globeKey() -> ShortcutCheck.GlobeKeyAction {
        let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
        return value.flatMap(ShortcutCheck.GlobeKeyAction.init(rawValue:)) ?? .emoji
    }

    static func issues(for shortcut: Shortcut) -> [ShortcutIssue] {
        ShortcutCheck.issues(for: shortcut, systemHotKeys: hotKeys(), globeKey: globeKey())
    }

    /// Opens System Settings where the problem can be fixed.
    static func open(_ fix: ShortcutIssue.Fix) {
        let url = switch fix {
        case .keyboardShortcuts, .globeKey: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        }
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}
