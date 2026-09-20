import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Posts the two shortcuts Grammar AI ever synthesizes: Cmd+C and Cmd+V.
/// It never listens to the keyboard - there is no event tap anywhere in the
/// app - so it needs Accessibility only, not Input Monitoring.
public protocol KeySimulating: Sendable {
    /// False while a password field (or Terminal's Secure Keyboard Entry)
    /// holds secure input; synthetic events must not be sent then.
    var isSecureInputActive: Bool { get }
    func waitForModifierRelease(timeout: TimeInterval) async
    func postCopy() async
    func postPaste() async
}

public struct KeySimulator: KeySimulating {

    public init() {}

    public var isSecureInputActive: Bool {
        IsSecureEventInputEnabled()
    }

    /// The hotkey fires while the user still holds Command and Shift. Our
    /// events carry their own flags, but a few apps consult the live
    /// modifier state, so give the user a moment to let go. Bounded: this is
    /// a short wait on one state flag, not keyboard monitoring.
    public func waitForModifierRelease(timeout: TimeInterval) async {
        let mask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if CGEventSource.flagsState(.combinedSessionState).intersection(mask).isEmpty { return }
            await pause(0.01)
        }
    }

    public func postCopy() async {
        let keyCode = await KeyboardLayout.keyCode(forCommandCharacter: "c", fallback: KeyboardLayout.ansiC)
        Self.postCommandKey(keyCode)
    }

    public func postPaste() async {
        let keyCode = await KeyboardLayout.keyCode(forCommandCharacter: "v", fallback: KeyboardLayout.ansiV)
        Self.postCommandKey(keyCode)
    }

    private static func postCommandKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Keep the user's own typing from being merged into our events.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { continue }
            // Exactly Command: a still-held Shift must not turn Cmd+V into
            // Cmd+Shift+V (Paste and Match Style).
            event.flags = .maskCommand
            event.post(tap: .cgSessionEventTap)
        }
    }
}
