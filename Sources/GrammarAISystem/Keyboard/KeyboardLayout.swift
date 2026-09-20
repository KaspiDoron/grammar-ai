import Carbon.HIToolbox
import Foundation
import GrammarAICore

/// Answers "which physical key is C right now?".
///
/// Virtual key 8 is "C" only on QWERTY-like layouts; on Dvorak or AZERTY it
/// is another key entirely. With a Hebrew (or other non-Latin) layout the
/// key types a Hebrew letter, but macOS maps it back to "c" while Command is
/// held. So the lookup translates every key code WITH the Command modifier
/// for the current layout - the same question the system asks when it
/// matches Cmd+C.
///
/// Text Input Source functions must run on the main thread.
@MainActor
public enum KeyboardLayout {

    /// ANSI positions, used only if no layout could be consulted.
    public static let ansiC: CGKeyCode = 8
    public static let ansiV: CGKeyCode = 9

    public static func keyCode(forCommandCharacter character: Character, fallback: CGKeyCode) -> CGKeyCode {
        let target = String(character).lowercased()
        let sources = [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        ]
        for case let source? in sources {
            guard let layout = layoutData(of: source) else { continue }
            // The fallback key first: on most layouts it is the answer, and
            // it keeps the physical position when several keys would match.
            let candidates = [fallback] + (0..<128).map { CGKeyCode($0) }.filter { $0 != fallback }
            for keyCode in candidates
            where translate(keyCode: keyCode, carbonModifiers: UInt32(cmdKey), layout: layout)?.lowercased() == target {
                return keyCode
            }
        }
        return fallback
    }

    /// Label for a shortcut's key, e.g. "G". Uses the ASCII-capable layout,
    /// which is how macOS itself draws shortcuts in menus.
    public static func label(forKeyCode keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layout = layoutData(of: source),
              let text = translate(keyCode: CGKeyCode(keyCode), carbonModifiers: 0, layout: layout)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return trimmed.isEmpty ? nil : trimmed.uppercased()
    }

    // MARK: - UCKeyTranslate

    private static func layoutData(of source: TISInputSource) -> Data? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.isEmpty ? nil : data
    }

    private static func translate(keyCode: CGKeyCode, carbonModifiers: UInt32, layout: Data) -> String? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                base,
                keyCode,
                UInt16(kUCKeyActionDown),
                (carbonModifiers >> 8) & 0xFF,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}

extension KeyCombo {
    /// The shortcut as macOS would draw it, e.g. "⇧⌘G", using the user's
    /// keyboard layout for the key's label.
    @MainActor
    public var localizedDisplayString: String {
        displayString(keyLabel: keyLabel)
    }

    @MainActor
    public var localizedSpokenDescription: String {
        spokenDescription(keyLabel: keyLabel)
    }

    /// Fixed labels (arrows, F-keys, Space) first: the layout translates
    /// those to private-use characters that do not render.
    @MainActor
    public var keyLabel: String {
        KeyCombo.specialKeyLabels[keyCode]
            ?? KeyboardLayout.label(forKeyCode: keyCode)
            ?? KeyCombo.fallbackKeyLabel(for: keyCode)
    }
}
