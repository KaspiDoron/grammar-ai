import Carbon.HIToolbox
import Foundation
import GrammarAICore

/// A reason the user might not want a particular shortcut.
public struct HotkeyConflict: Equatable, Sendable {
    public enum Severity: Sendable {
        /// macOS itself uses it; ours would likely never fire.
        case system
        /// It works, but it takes a common shortcut away from other apps.
        case common
    }

    public let severity: Severity
    public let message: String
}

/// Conflict detection. Registering a hotkey another app already holds
/// SUCCEEDS on macOS (verified, see docs/RESEARCH.md), so a failed
/// registration tells us nothing. Instead we check the system's own
/// shortcut table and a short list of shortcuts nearly every app uses.
public enum HotkeyConflicts {

    public static func conflict(for combo: KeyCombo) -> HotkeyConflict? {
        if systemShortcuts().contains(combo) {
            return HotkeyConflict(
                severity: .system,
                message: "macOS already uses this shortcut. Pick another, or turn it off in System Settings > Keyboard > Keyboard Shortcuts."
            )
        }
        if let use = commonShortcuts[combo] {
            return HotkeyConflict(
                severity: .common,
                message: "This is \(use) in many apps. It will stop working there while Grammar AI is enabled."
            )
        }
        return nil
    }

    /// Enabled system-wide shortcuts (Spotlight, screenshots, Mission
    /// Control, input source switching...) as macOS reports them.
    static func systemShortcuts() -> Set<KeyCombo> {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var result = Set<KeyCombo>()
        for entry in entries {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int,
                  code >= 0, code < 0xFFFF
            else { continue }
            let combo = KeyCombo(keyCode: UInt32(code), modifiers: .init(carbonFlags: UInt32(truncatingIfNeeded: modifiers)))
            if combo.isValidGlobalShortcut { result.insert(combo) }
        }
        return result
    }

    /// Key codes are ANSI positions (`kVK_ANSI_*`).
    static let commonShortcuts: [KeyCombo: String] = {
        let command: KeyCombo.Modifiers = [.command]
        let commandShift: KeyCombo.Modifiers = [.command, .shift]
        let entries: [(UInt32, KeyCombo.Modifiers, String)] = [
            (8, command, "Copy"), (9, command, "Paste"), (7, command, "Cut"),
            (6, command, "Undo"), (6, commandShift, "Redo"), (0, command, "Select All"),
            (1, command, "Save"), (1, commandShift, "Save As"), (12, command, "Quit"),
            (13, command, "Close Window"), (17, command, "New Tab"), (17, commandShift, "Reopen Tab"),
            (45, command, "New"), (45, commandShift, "New Window"), (31, command, "Open"),
            (35, command, "Print"), (3, command, "Find"), (5, command, "Find Next"),
            (5, commandShift, "Find Previous (and Go to Folder in Finder)"),
            (4, command, "Hide"), (46, command, "Minimize"), (43, command, "Settings"),
            (15, command, "Reload"), (37, command, "Open Location"), (11, command, "Bold"),
            (34, command, "Italic"), (32, command, "Underline"), (40, command, "Insert Link"),
            (48, command, "the app switcher"), (49, command, "Spotlight"),
            (20, commandShift, "Screenshot"), (21, commandShift, "Screenshot"), (23, commandShift, "Screenshot")
        ]
        return Dictionary(entries.map { (KeyCombo(keyCode: $0.0, modifiers: $0.1), $0.2) }, uniquingKeysWith: { first, _ in first })
    }()
}
