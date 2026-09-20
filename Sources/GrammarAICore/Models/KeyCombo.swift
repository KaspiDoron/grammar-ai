import Foundation

/// A global keyboard shortcut: a virtual key code plus modifiers. Pure data,
/// so it is Codable, testable and free of Carbon/AppKit types. The system
/// layer converts it to Carbon modifiers when registering the hotkey.
public struct KeyCombo: Codable, Equatable, Hashable, Sendable {

    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        /// Symbols in the order macOS menus draw them.
        public var symbols: String {
            var result = ""
            if contains(.control) { result += "\u{2303}" }
            if contains(.option) { result += "\u{2325}" }
            if contains(.shift) { result += "\u{21E7}" }
            if contains(.command) { result += "\u{2318}" }
            return result
        }

        /// Words for VoiceOver, which reads the symbols poorly.
        public var spokenNames: [String] {
            var names: [String] = []
            if contains(.control) { names.append("Control") }
            if contains(.option) { names.append("Option") }
            if contains(.shift) { names.append("Shift") }
            if contains(.command) { names.append("Command") }
            return names
        }
    }

    /// Virtual key code (`kVK_*`). Layout independent: it names a physical key.
    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Command-Shift-G, the product default. `5` is `kVK_ANSI_G`.
    public static let defaultCorrection = KeyCombo(keyCode: 5, modifiers: [.command, .shift])

    /// A global shortcut without Command, Control or Option would swallow
    /// ordinary typing (Shift-G is just "G"), so it is never accepted.
    public var isValidGlobalShortcut: Bool {
        !modifiers.intersection([.command, .control, .option]).isEmpty
    }

    /// e.g. "⇧⌘G". `keyLabel` comes from the active keyboard layout when the
    /// system layer can resolve it, else from `fallbackKeyLabel`.
    public func displayString(keyLabel: String? = nil) -> String {
        modifiers.symbols + (keyLabel ?? Self.fallbackKeyLabel(for: keyCode))
    }

    public func spokenDescription(keyLabel: String? = nil) -> String {
        (modifiers.spokenNames + [keyLabel ?? Self.fallbackKeyLabel(for: keyCode)]).joined(separator: " ")
    }

    // MARK: - Key labels

    /// Keys whose label does not depend on the keyboard layout.
    public static let specialKeyLabels: [UInt32: String] = [
        36: "\u{21A9}", 48: "\u{21E5}", 49: "Space", 51: "\u{232B}", 53: "\u{238B}",
        71: "\u{2327}", 76: "\u{2305}", 115: "\u{2196}", 116: "\u{21DE}", 117: "\u{2326}",
        119: "\u{2198}", 121: "\u{21DF}", 123: "\u{2190}", 124: "\u{2192}",
        125: "\u{2193}", 126: "\u{2191}",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
        107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]

    /// US ANSI labels, used only when the live layout cannot be consulted.
    private static let ansiKeyLabels: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        50: "`"
    ]

    public static func fallbackKeyLabel(for keyCode: UInt32) -> String {
        specialKeyLabels[keyCode] ?? ansiKeyLabels[keyCode] ?? "Key \(keyCode)"
    }
}
