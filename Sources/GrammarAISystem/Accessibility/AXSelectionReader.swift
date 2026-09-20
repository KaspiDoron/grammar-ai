import ApplicationServices
import Foundation

/// What Accessibility could tell us about the focused element's selection.
public enum AXSelectionResult: Equatable, Sendable {
    /// Selected text, plus whether the element is known to be read-only.
    case text(String, isEditable: Bool?)
    /// A password field has focus. We never read it.
    case secureField
    /// The app answered, and exposes no usable selection through
    /// Accessibility (common for Chromium and Electron apps). The caller
    /// falls back to the clipboard.
    case unavailable
    /// The app did not answer in time. It is busy - which says nothing about
    /// its selection, and in particular does NOT mean a paste has landed.
    case failed
}

public protocol AXSelectionReading: Sendable {
    func readSelection(processID: pid_t?) -> AXSelectionResult
}

/// Reads the selection with the Accessibility API: no keystrokes, no
/// clipboard, no side effects. Calls are synchronous IPC into the target
/// app, so callers run this off the main thread and every element gets a
/// short messaging timeout - a hung app must not hang us.
public struct AXSelectionReader: AXSelectionReading {

    private let messagingTimeout: Float

    public init(messagingTimeout: Float = 0.6) {
        self.messagingTimeout = messagingTimeout
    }

    public func readSelection(processID: pid_t?) -> AXSelectionResult {
        var timedOut = false
        guard let element = focusedElement(processID: processID, timedOut: &timedOut) else {
            return timedOut ? .failed : .unavailable
        }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        if stringAttribute(kAXSubroleAttribute, of: element) == (kAXSecureTextFieldSubrole as String) {
            return .secureField
        }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        if status == .cannotComplete { return .failed }
        guard status == .success, let text = value as? String, !text.isEmpty else {
            return .unavailable
        }
        return .text(text, isEditable: editability(of: element))
    }

    // MARK: - Helpers

    private func focusedElement(processID: pid_t?, timedOut: inout Bool) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        if let element = elementAttribute(kAXFocusedUIElementAttribute, of: systemWide, timedOut: &timedOut) {
            return element
        }
        // Some apps answer on their own element but not system-wide.
        guard let processID else { return nil }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        return elementAttribute(kAXFocusedUIElementAttribute, of: application, timedOut: &timedOut)
    }

    /// `false` only when Accessibility is positive the element cannot be
    /// edited; anything unclear is `nil` so we do not block a valid paste.
    private func editability(of element: AXUIElement) -> Bool? {
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        let readOnlyRoles: Set<String> = [kAXStaticTextRole as String, "AXWebArea", kAXImageRole as String]
        if let role = stringAttribute(kAXRoleAttribute, of: element), readOnlyRoles.contains(role) {
            return false
        }
        return nil
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func elementAttribute(_ attribute: String, of element: AXUIElement, timedOut: inout Bool) -> AXUIElement? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if status == .cannotComplete { timedOut = true }
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // Checked the type ID above, so the cast cannot fail.
        return (value as! AXUIElement)
    }
}
