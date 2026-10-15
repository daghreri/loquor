import Foundation

/// The dictation shortcut: either modifiers alone (side-specific, e.g. fn + Left
/// Shift, Right Option) or modifiers plus one key (e.g. ⌃⌥Space; sides don't matter).
public struct Shortcut: Codable, Equatable, Sendable {
    public var modifiers: Modifiers
    public var keyCode: UInt16?

    public init(modifiers: Modifiers, keyCode: UInt16? = nil) {
        self.modifiers = modifiers
        self.keyCode = keyCode
    }

    /// The default: a chord no app uses on its own.
    public static let `default` = Shortcut(modifiers: [.fn, .leftShift])

    public var isModifierOnly: Bool { keyCode == nil }

    /// Does this set of held modifiers (plus a pressed key) make the shortcut?
    /// Modifier-only shortcuts need exactly these keys, sides included; key
    /// shortcuts need exactly these modifiers on either side.
    public func matches(held: Modifiers, key: UInt16? = nil) -> Bool {
        if let keyCode {
            return key == keyCode && held.generic == modifiers.generic
        }
        return key == nil && held == modifiers
    }

    public var displayName: String {
        var parts = modifiers.names(sided: isModifierOnly)
        if let keyCode { parts.append(KeyNames.name(keyCode)) }
        return parts.joined(separator: " + ")
    }
}

/// Modifier keys, left and right separately (fn has one side).
public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let fn = Modifiers(rawValue: 1 << 0)
    public static let leftControl = Modifiers(rawValue: 1 << 1)
    public static let rightControl = Modifiers(rawValue: 1 << 2)
    public static let leftOption = Modifiers(rawValue: 1 << 3)
    public static let rightOption = Modifiers(rawValue: 1 << 4)
    public static let leftShift = Modifiers(rawValue: 1 << 5)
    public static let rightShift = Modifiers(rawValue: 1 << 6)
    public static let leftCommand = Modifiers(rawValue: 1 << 7)
    public static let rightCommand = Modifiers(rawValue: 1 << 8)

    public static let control: Modifiers = [.leftControl, .rightControl]
    public static let option: Modifiers = [.leftOption, .rightOption]
    public static let shift: Modifiers = [.leftShift, .rightShift]
    public static let command: Modifiers = [.leftCommand, .rightCommand]

    /// From CGEventFlags' raw value: the generic bits plus the NX_DEVICE* side bits.
    public init(cgFlags raw: UInt64) {
        var m: Modifiers = []
        if raw & 0x80_0000 != 0 { m.insert(.fn) }  // maskSecondaryFn
        func side(_ generic: UInt64, _ left: UInt64, _ right: UInt64, _ l: Modifiers, _ r: Modifiers) {
            guard raw & generic != 0 else { return }
            if raw & left != 0 { m.insert(l) }
            if raw & right != 0 { m.insert(r) }
            if raw & (left | right) == 0 { m.insert(l) }  // keyboard without side bits
        }
        side(0x04_0000, 0x0001, 0x2000, .leftControl, .rightControl)
        side(0x08_0000, 0x0020, 0x0040, .leftOption, .rightOption)
        side(0x02_0000, 0x0002, 0x0004, .leftShift, .rightShift)
        side(0x10_0000, 0x0008, 0x0010, .leftCommand, .rightCommand)
        self = m
    }

    /// Sides folded together (left and right both become "both").
    public var generic: Modifiers {
        var g: Modifiers = []
        if contains(.fn) { g.insert(.fn) }
        if !intersection(.control).isEmpty { g.formUnion(.control) }
        if !intersection(.option).isEmpty { g.formUnion(.option) }
        if !intersection(.shift).isEmpty { g.formUnion(.shift) }
        if !intersection(.command).isEmpty { g.formUnion(.command) }
        return g
    }

    /// The mask macOS uses in com.apple.symbolichotkeys (fn left out).
    public var symbolicHotKeyMask: Int {
        var m = 0
        if !intersection(.shift).isEmpty { m |= 0x02_0000 }
        if !intersection(.control).isEmpty { m |= 0x04_0000 }
        if !intersection(.option).isEmpty { m |= 0x08_0000 }
        if !intersection(.command).isEmpty { m |= 0x10_0000 }
        return m
    }

    public var count: Int { rawValue.nonzeroBitCount }

    func names(sided: Bool) -> [String] {
        let table: [(Modifiers, String, String)] = [
            (.fn, "fn", "fn"),
            (.leftControl, "Left Control", "Control"), (.rightControl, "Right Control", "Control"),
            (.leftOption, "Left Option", "Option"), (.rightOption, "Right Option", "Option"),
            (.leftShift, "Left Shift", "Shift"), (.rightShift, "Right Shift", "Shift"),
            (.leftCommand, "Left Command", "Command"), (.rightCommand, "Right Command", "Command"),
        ]
        var out: [String] = []
        for (flag, sidedName, plain) in table where contains(flag) {
            let name = sided ? sidedName : plain
            if !out.contains(name) { out.append(name) }
        }
        return out
    }
}

/// US-layout names for key codes (kVK_*), for display.
public enum KeyNames {
    static let table: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K",
        41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space",
        50: "`", 51: "Delete", 53: "Esc", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13",
        106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "Home",
        116: "Page Up", 117: "Forward Delete", 118: "F4", 119: "End", 120: "F2", 121: "Page Down",
        122: "F1", 123: "Left Arrow", 124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow",
    ]

    public static func name(_ code: UInt16) -> String { table[code] ?? "Key \(code)" }

    static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                            105, 107, 113, 106, 64, 79, 80, 90]
    static let navigationKeys: Set<UInt16> = [115, 116, 117, 119, 121, 123, 124, 125, 126, 114]
    static let escape: UInt16 = 53
}
