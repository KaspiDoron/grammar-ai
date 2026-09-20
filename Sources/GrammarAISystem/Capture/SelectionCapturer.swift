import Foundation
import GrammarAICore

/// Captures the selected text from whatever app is frontmost.
///
/// 1. Accessibility - instant, no side effects, works in native and WebKit
///    text fields.
/// 2. Clipboard copy - the universal fallback for apps that expose nothing
///    through Accessibility. The clipboard is saved and restored.
///
/// Password fields are never read on either path.
public struct SelectionCapturer: TextSelectionCapturing {

    private let isAccessibilityGranted: @Sendable () -> Bool
    private let frontmost: FrontmostAppProviding
    private let axReader: AXSelectionReading
    private let keys: KeySimulating
    private let copier: ClipboardSelectionCopier

    public init(
        isAccessibilityGranted: @escaping @Sendable () -> Bool = { AccessibilityPermission.isGranted },
        frontmost: FrontmostAppProviding = WorkspaceFrontmostAppProvider(),
        axReader: AXSelectionReading = AXSelectionReader(),
        clipboard: ClipboardAccessing = SystemClipboard(),
        keys: KeySimulating = KeySimulator(),
        timing: SystemTiming = .standard
    ) {
        self.isAccessibilityGranted = isAccessibilityGranted
        self.frontmost = frontmost
        self.axReader = axReader
        self.keys = keys
        self.copier = ClipboardSelectionCopier(clipboard: clipboard, keys: keys, timing: timing)
    }

    public func captureSelection() async throws -> CapturedSelection {
        guard isAccessibilityGranted() else { throw CorrectionError.accessibilityDenied }
        // Secure input means a password field (or Terminal's Secure Keyboard
        // Entry) has the keyboard. Stay out entirely.
        guard !keys.isSecureInputActive else { throw CorrectionError.secureField }

        let app = await frontmost.current()

        switch axReader.readSelection(processID: app?.processID) {
        case .secureField:
            throw CorrectionError.secureField
        case .text(let text, let isEditable):
            Log.info(.capture, "captured via accessibility")
            return CapturedSelection(
                text: text, source: .accessibility,
                appBundleID: app?.bundleID, appName: app?.name,
                processID: app?.processID, isEditable: isEditable
            )
        case .unavailable, .failed:
            break
        }

        guard let text = await copier.copySelection() else {
            throw CorrectionError.noSelection
        }
        Log.info(.capture, "captured via clipboard")
        // One line ending in a newline, from an editor that copies the line
        // when nothing is selected: it may not be a selection at all.
        let body = text.dropLast()
        let looksLikeLineCopy = text.hasSuffix("\n") && !body.isEmpty && !body.contains(where: \.isNewline)
        return CapturedSelection(
            text: text, source: .pasteboard,
            appBundleID: app?.bundleID, appName: app?.name,
            processID: app?.processID, isEditable: nil,
            isAmbiguousLineCopy: looksLikeLineCopy && (app?.copiesLineWhenNothingSelected ?? false)
        )
    }
}
