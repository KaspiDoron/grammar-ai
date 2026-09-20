import Carbon.HIToolbox
import Foundation
import GrammarAICore

public enum HotkeyError: Error, Equatable, Sendable {
    /// The combination has no Command, Control or Option.
    case invalidCombination
    /// macOS refused the registration (Carbon status attached).
    case registrationFailed(Int32)
}

extension KeyCombo.Modifiers {
    /// Carbon's modifier bits, as `RegisterEventHotKey` expects them.
    public var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        return flags
    }

    public init(carbonFlags: UInt32) {
        var modifiers: KeyCombo.Modifiers = []
        if carbonFlags & UInt32(cmdKey) != 0 { modifiers.insert(.command) }
        if carbonFlags & UInt32(shiftKey) != 0 { modifiers.insert(.shift) }
        if carbonFlags & UInt32(optionKey) != 0 { modifiers.insert(.option) }
        if carbonFlags & UInt32(controlKey) != 0 { modifiers.insert(.control) }
        self = modifiers
    }
}

/// The global keyboard shortcut, registered with Carbon's
/// `RegisterEventHotKey`.
///
/// Why this API: it needs no permission at all, and macOS delivers ONLY our
/// combination - the app never sees any other keystroke. The alternatives
/// (event taps, global monitors) observe every key the user types, which is
/// exactly what a privacy-first tool must not do.
@MainActor
public final class HotkeyManager {

    /// Called on the main thread each time the shortcut is pressed.
    public var onTrigger: (() -> Void)?

    public private(set) var registeredCombo: KeyCombo?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4752_4149 // "GRAI"

    public init() {}

    /// Registers `combo`, replacing any previous shortcut. On failure the
    /// previous shortcut stays unregistered and the error says why.
    public func register(_ combo: KeyCombo) throws(HotkeyError) {
        unregister()
        guard combo.isValidGlobalShortcut else { throw .invalidCombination }
        try installHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers.carbonFlags,
            EventHotKeyID(signature: Self.signature, id: 1),
            GetEventDispatcherTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            Log.error(.hotkey, "registration failed", detail: "status \(status)")
            throw .registrationFailed(status)
        }
        hotKeyRef = reference
        registeredCombo = combo
        Log.info(.hotkey, "registered")
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        registeredCombo = nil
    }

    private func installHandlerIfNeeded() throws(HotkeyError) {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotkeyEventHandler,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard status == noErr else { throw .registrationFailed(status) }
    }

    fileprivate func handlePressed() {
        onTrigger?()
    }
}

/// Carbon calls this C function on the main thread (the event dispatcher
/// target is serviced by the main run loop).
private func hotkeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.handlePressed()
    }
    return noErr
}
