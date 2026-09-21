import ApplicationServices
import AppKit
import GrammarAICore

/// A snapshot of the focused editable text and where its caret is.
public struct FocusedTextField: Sendable {
    /// The whole value of the focused field.
    public let value: String
    /// The caret position (insertion point) as a character offset into `value`.
    public let caret: Int
    /// Screen rect (Cocoa, bottom-left origin) of the caret / insertion point,
    /// if the app exposes it. Used to place the suggestion near the caret.
    public let caretBounds: CGRect?
    public let processID: pid_t
    public let appBundleID: String?

    public init(value: String, caret: Int, caretBounds: CGRect?, processID: pid_t, appBundleID: String?) {
        self.value = value
        self.caret = caret
        self.caretBounds = caretBounds
        self.processID = processID
        self.appBundleID = appBundleID
    }
}

/// Watches the frontmost app's focused text field and reports when its value
/// changes - via Accessibility notifications, NOT by observing the keyboard.
/// This is how a screen reader follows a text field; Typfix uses it only when
/// the user turns on automatic suggestions, and only reads the focused field.
///
/// All Accessibility calls and the callback run on the main thread.
@MainActor
public final class AXTextMonitor {

    /// Called (on the main thread) shortly after the focused field's value
    /// changes and the user pauses. Debouncing is the monitor's job.
    public var onChange: ((FocusedTextField) -> Void)?
    /// Called when focus leaves a text field, so any open suggestion hides.
    public var onFocusLost: (() -> Void)?

    private let debounce: TimeInterval
    private var observer: AXObserver?
    private var observedApp: AXUIElement?
    private var observedElement: AXUIElement?
    private var observedPID: pid_t = 0
    private var debounceTimer: Timer?
    private var focusPollTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var lastValue: String?

    public init(debounce: TimeInterval = 1.1) {
        self.debounce = debounce
    }

    public var isRunning: Bool { observer != nil || focusPollTimer != nil }

    public func start() {
        guard AccessibilityPermission.isGranted else { return }
        guard workspaceObserver == nil else { return }
        // Re-attach whenever the frontmost app changes.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachToFrontmostApp() }
        }
        attachToFrontmostApp()
    }

    public func stop() {
        debounceTimer?.invalidate(); debounceTimer = nil
        focusPollTimer?.invalidate(); focusPollTimer = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil
        teardownObserver()
        lastValue = nil
    }

    // MARK: - Attaching

    private func attachToFrontmostApp() {
        teardownObserver()
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        // Don't observe ourselves.
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }

        observedPID = pid
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        observedApp = appElement

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<AXTextMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.handleNotification() }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else {
            // Some apps refuse observers; fall back to a light focus poll.
            startFocusPoll()
            return
        }
        self.observer = observer
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Focus changes at the app level; value changes on the focused field.
        AXObserverAddNotification(observer, appElement, kAXFocusedUIElementChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        refreshObservedElement()
    }

    private func teardownObserver() {
        debounceTimer?.invalidate(); debounceTimer = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            if let observedElement {
                AXObserverRemoveNotification(observer, observedElement, kAXValueChangedNotification as CFString)
            }
            if let observedApp {
                AXObserverRemoveNotification(observer, observedApp, kAXFocusedUIElementChangedNotification as CFString)
            }
        }
        observer = nil
        observedApp = nil
        observedElement = nil
    }

    /// When focus moves, observe value changes on the new focused element.
    private func refreshObservedElement() {
        guard let observer, let observedApp else { return }
        if let current = observedElement {
            AXObserverRemoveNotification(observer, current, kAXValueChangedNotification as CFString)
            observedElement = nil
        }
        guard let focused = copyElement(observedApp, kAXFocusedUIElementAttribute) else {
            onFocusLost?()
            return
        }
        // Only editable text elements are worth watching.
        guard isEditableText(focused) else {
            onFocusLost?()
            return
        }
        AXUIElementSetMessagingTimeout(focused, 0.5)
        observedElement = focused
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, focused, kAXValueChangedNotification as CFString, refcon)
    }

    // MARK: - Notifications

    private func handleNotification() {
        // Focus may have changed; make sure we track the current field.
        refreshObservedElement()
        scheduleDebounced()
    }

    private func scheduleDebounced() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounce, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.emitIfChanged() }
        }
    }

    private func emitIfChanged() {
        guard let field = readFocusedField() else { onFocusLost?(); return }
        guard field.value != lastValue else { return }
        lastValue = field.value
        onChange?(field)
    }

    /// A fallback for apps that reject an AX observer: poll the focused field
    /// value at a slow cadence while this app is not frontmost.
    private func startFocusPoll() {
        focusPollTimer?.invalidate()
        focusPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.emitIfChanged() }
        }
    }

    // MARK: - Reading the field

    private func readFocusedField() -> FocusedTextField? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
        guard let focused = copyElement(systemWide, kAXFocusedUIElementAttribute) ??
                (observedApp.flatMap { copyElement($0, kAXFocusedUIElementAttribute) }),
              isEditableText(focused) else { return nil }

        guard let value = copyString(focused, kAXValueAttribute) else { return nil }
        let caret = caretOffset(of: focused) ?? value.count
        let bounds = caretBounds(of: focused, at: caret)
        let app = NSWorkspace.shared.frontmostApplication
        return FocusedTextField(
            value: value,
            caret: min(caret, value.count),
            caretBounds: bounds,
            processID: app?.processIdentifier ?? observedPID,
            appBundleID: app?.bundleIdentifier
        )
    }

    private func isEditableText(_ element: AXUIElement) -> Bool {
        if copyString(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) { return false }
        let role = copyString(element, kAXRoleAttribute)
        guard role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String) else { return false }
        // Must be settable, i.e. actually editable.
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue
    }

    private func caretOffset(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    private func caretBounds(of element: AXUIElement, at offset: Int) -> CGRect? {
        var range = CFRange(location: offset, length: 0)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, axRange, &boundsValue) == .success,
            let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else { return nil }
        // AX rects are top-left origin in global (flipped) coordinates.
        // Convert to Cocoa's bottom-left origin using the primary screen height.
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return rect }
        return CGRect(x: rect.origin.x, y: primaryHeight - rect.origin.y - rect.height, width: rect.width, height: rect.height)
    }

    // MARK: - AX helpers

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
