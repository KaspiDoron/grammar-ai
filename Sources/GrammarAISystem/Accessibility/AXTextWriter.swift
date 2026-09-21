import ApplicationServices
import AppKit

/// Applies an accepted as-you-type suggestion to the focused field by setting
/// its value through Accessibility. Only ever used on a field we are already
/// monitoring (native, editable, not secure), so the write is well defined.
@MainActor
public enum AXTextWriter {

    public enum Outcome: Equatable, Sendable {
        case wrote
        case failed
    }

    /// Replaces the focused field's whole value and repositions the caret.
    /// Returns `.failed` if the field is not the one we expect, or the write
    /// does not take - the caller then leaves the text untouched.
    @discardableResult
    public static func setFocusedValue(_ newValue: String, caret: Int, expectedProcessID: pid_t) -> Outcome {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == expectedProcessID else { return .failed }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return .failed }
        let element = focusedRef as! AXUIElement

        // Refuse anything that is not editable or is a password field.
        if subrole(element) == (kAXSecureTextFieldSubrole as String) { return .failed }
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard settable.boolValue else { return .failed }

        let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newValue as CFTypeRef)
        guard status == .success else { return .failed }

        // Verify it actually took (some apps report success but ignore it).
        var check: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &check) == .success,
           let current = check as? String, current != newValue {
            return .failed
        }

        // Put the caret where the text now ends of the replacement.
        var range = CFRange(location: caret, length: 0)
        if let axRange = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
        }
        return .wrote
    }

    private static func subrole(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
