import Foundation
import GrammarAICore

/// Puts a validated correction over the user's selection by pasting it.
///
/// Paste is used everywhere because it runs through each app's normal
/// editing path: it works in rich web editors and is undoable with Cmd+Z.
///
/// The model call took about a second, and the user may have moved on. So
/// right before pasting this re-checks that the same app is frontmost and
/// the same text is still selected. If anything is off it does NOT paste:
/// the correction goes to the clipboard and the user is told. The failure
/// mode is always "nothing changed", never "the wrong thing changed".
public struct TextReplacer: TextReplacing, ClipboardWriting {

    private let isAccessibilityGranted: @Sendable () -> Bool
    private let frontmost: FrontmostAppProviding
    private let axReader: AXSelectionReading
    private let clipboard: ClipboardAccessing
    private let keys: KeySimulating
    private let timing: SystemTiming
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
        self.clipboard = clipboard
        self.keys = keys
        self.timing = timing
        self.copier = ClipboardSelectionCopier(clipboard: clipboard, keys: keys, timing: timing)
    }

    public func copyToClipboard(_ text: String) async {
        await clipboard.write(text)
    }

    public func replace(selection: CapturedSelection, with correctedText: String) async throws -> ReplacementOutcome {
        guard isAccessibilityGranted() else { throw CorrectionError.accessibilityDenied }

        guard let app = await frontmost.current(),
              selection.processID == nil || app.processID == selection.processID else {
            return await copyInstead(correctedText, reason: "You switched apps, so the correction was copied instead.")
        }
        if app.isTerminal {
            return await copyInstead(correctedText, reason: "Terminals can't be edited in place. Correction copied.")
        }
        if selection.isEditable == false {
            return await copyInstead(correctedText, reason: "This text can't be edited. Correction copied.")
        }
        if selection.isAmbiguousLineCopy {
            return await copyInstead(correctedText, reason: "Couldn't confirm the selection in this editor. Correction copied.")
        }
        if keys.isSecureInputActive {
            return await copyInstead(correctedText, reason: "A secure field is active. Correction copied.")
        }

        // Is the text we captured still what is selected?
        var accessibilityCanObserve = false
        switch axReader.readSelection(processID: app.processID) {
        case .text(let current, _):
            guard current == selection.text else {
                return await copyInstead(correctedText, reason: "The selection changed. Correction copied.")
            }
            accessibilityCanObserve = true
        case .secureField:
            return await copyInstead(correctedText, reason: "A secure field is active. Correction copied.")
        case .failed:
            // The app is too busy to tell us what is selected. Do not guess.
            return await copyInstead(correctedText, reason: "The app is busy. Correction copied.")
        case .unavailable:
            if selection.source == .accessibility {
                // Accessibility saw a selection before and sees none now:
                // the user deselected. Pasting would insert a duplicate.
                return await copyInstead(correctedText, reason: "The selection changed. Correction copied.")
            }
            // The app is invisible to Accessibility, so ask it the same way
            // we captured: copy again and compare.
            guard await copier.copySelection() == selection.text else {
                return await copyInstead(correctedText, reason: "The selection changed. Correction copied.")
            }
        }

        // Last exit before the clipboard is borrowed: a cancelled run must
        // not paste. Past this point nothing throws, so the clipboard is
        // always restored.
        try Task.checkCancellation()

        let saved = await clipboard.snapshot()
        let ourChangeCount = await clipboard.writeTransient(correctedText)

        await keys.waitForModifierRelease(timeout: timing.modifierReleaseTimeout)
        await keys.postPaste()
        await waitUntilPasteLanded(
            original: selection.text,
            processID: app.processID,
            accessibilityCanObserve: accessibilityCanObserve
        )

        // Restore the user's clipboard - unless something else wrote to it
        // while we waited, in which case that newer content wins.
        if await clipboard.changeCount() == ourChangeCount {
            await clipboard.restore(saved)
        }
        Log.info(.replace, "replaced selection")
        return .replaced
    }

    // MARK: - Helpers

    private func copyInstead(_ text: String, reason: String) async -> ReplacementOutcome {
        await clipboard.write(text)
        Log.info(.replace, "copied instead of pasting")
        return .copiedToClipboard(reason: reason)
    }

    /// Restoring the clipboard before the target app has read it would make
    /// the app paste the OLD clipboard over the selection - the one way this
    /// design could destroy text. So: always wait a floor, then wait until
    /// Accessibility shows the selection is gone (the paste replaced it), up
    /// to a cap. Apps Accessibility cannot see get a fixed, generous wait.
    private func waitUntilPasteLanded(original: String, processID: pid_t, accessibilityCanObserve: Bool) async {
        guard accessibilityCanObserve else {
            await pause(timing.pasteBlindWait)
            return
        }
        await pause(timing.pasteFloor)
        let deadline = Date().addingTimeInterval(max(0, timing.pasteCap - timing.pasteFloor))
        while Date() < deadline {
            switch axReader.readSelection(processID: processID) {
            case .text(let current, _) where current == original:
                break // not pasted yet
            case .failed:
                break // the app is busy: it has NOT handled our paste yet
            case .text, .unavailable, .secureField:
                return // the selection is gone: the paste replaced it
            }
            await pause(max(timing.pollInterval, 0.05))
        }
    }
}
