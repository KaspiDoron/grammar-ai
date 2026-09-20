import Foundation
import GrammarAICore
import Testing
@testable import GrammarAISystem

/// Regression tests for the adversarial review findings (system layer).
@Suite("Hardening - capture and replace")
struct HardeningSystemTests {

    private let original = "helo wrold"
    private let corrected = "Hello world"

    @Test func aWholeLineCopyFromALineCopyEditorIsNeverPasted() async throws {
        let clipboard = FakeClipboard(text: "mine"), keys = FakeKeys()
        keys.onCopy = { clipboard.externalWrite("let total = items.count\n") }
        let sublime = FakeFrontmost(app: FrontmostApp(processID: 42, bundleID: "com.sublimetext.4", name: "Sublime Text"))
        let capturer = SelectionCapturer(isAccessibilityGranted: { true }, frontmost: sublime, axReader: FakeAX(.unavailable),
                                         clipboard: clipboard, keys: keys, timing: .immediate)
        let selection = try await capturer.captureSelection()
        #expect(selection.isAmbiguousLineCopy)

        let replacer = TextReplacer(isAccessibilityGranted: { true }, frontmost: sublime, axReader: FakeAX(.unavailable),
                                    clipboard: clipboard, keys: keys, timing: .immediate)
        guard case .copiedToClipboard = try await replacer.replace(selection: selection, with: "let total = items.count\n") else {
            Issue.record("expected a downgrade, not a paste")
            return
        }
        #expect(!keys.posted.contains("paste"))
    }

    @Test func theSameTextFromAnOrdinaryAppIsARealSelection() async throws {
        let clipboard = FakeClipboard(text: "mine"), keys = FakeKeys()
        keys.onCopy = { clipboard.externalWrite("a full line\n") }
        let capturer = SelectionCapturer(isAccessibilityGranted: { true }, frontmost: FakeFrontmost(), axReader: FakeAX(.unavailable),
                                         clipboard: clipboard, keys: keys, timing: .immediate)
        let selection = try await capturer.captureSelection()
        #expect(!selection.isAmbiguousLineCopy)
    }

    @Test func aBusyAppIsNotGuessedAt() async throws {
        let clipboard = FakeClipboard(text: "mine"), keys = FakeKeys()
        let replacer = TextReplacer(isAccessibilityGranted: { true }, frontmost: FakeFrontmost(), axReader: FakeAX(.failed),
                                    clipboard: clipboard, keys: keys, timing: .immediate)
        let selection = CapturedSelection(text: original, source: .accessibility, appBundleID: nil, appName: nil, processID: 42, isEditable: true)
        guard case .copiedToClipboard = try await replacer.replace(selection: selection, with: corrected) else {
            Issue.record("expected a downgrade")
            return
        }
        #expect(!keys.posted.contains("paste"))
    }

    @Test func aBusyAppAfterThePasteIsNotMistakenForALandedPaste() async throws {
        // Accessibility times out after Cmd+V: the app has NOT pasted yet, so
        // the clipboard must stay ours until the cap, not be restored early.
        let clipboard = FakeClipboard(text: "mine"), keys = FakeKeys()
        let clipboardAtFirstBusyPoll = Mutex<String?>(nil)
        final class ProbingAX: AXSelectionReading, @unchecked Sendable {
            let original: String, probe: @Sendable () -> Void
            private let lock = NSLock()
            private var calls = 0
            init(original: String, probe: @escaping @Sendable () -> Void) { self.original = original; self.probe = probe }
            func readSelection(processID: pid_t?) -> AXSelectionResult {
                let call = lock.withLock { calls += 1; return calls }
                if call == 1 { return .text(original, isEditable: true) } // pre-paste verification
                if call == 2 { probe() }
                return .failed
            }
        }
        let ax = ProbingAX(original: original) { clipboardAtFirstBusyPoll.set(clipboard.currentText) }
        let replacer = TextReplacer(isAccessibilityGranted: { true }, frontmost: FakeFrontmost(), axReader: ax,
                                    clipboard: clipboard, keys: keys, timing: .immediate)
        let selection = CapturedSelection(text: original, source: .accessibility, appBundleID: nil, appName: nil, processID: 42, isEditable: true)
        #expect(try await replacer.replace(selection: selection, with: corrected) == .replaced)
        #expect(clipboardAtFirstBusyPoll.value == corrected) // still ours while the app was busy
        #expect(clipboard.currentText == "mine")             // restored after the cap
    }

    @Test func aCancelledRunDoesNotBorrowTheClipboardOrPaste() async {
        let clipboard = FakeClipboard(text: "mine"), keys = FakeKeys()
        let replacer = TextReplacer(isAccessibilityGranted: { true }, frontmost: FakeFrontmost(),
                                    axReader: FakeAX(.text(original, isEditable: true)),
                                    clipboard: clipboard, keys: keys, timing: .immediate)
        let selection = CapturedSelection(text: original, source: .accessibility, appBundleID: nil, appName: nil, processID: 42, isEditable: true)
        let corrected = self.corrected
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await replacer.replace(selection: selection, with: corrected); return false } catch { return error is CancellationError }
        }
        #expect(await task.value)
        #expect(keys.posted.isEmpty)
        #expect(clipboard.currentText == "mine")
        #expect(!clipboard.log.contains("writeTransient"))
    }

    @Test func aCopyThatLandsLateIsUndone() async throws {
        let clipboard = FakeClipboard(text: "my precious clipboard"), keys = FakeKeys()
        keys.onCopy = {
            // A busy app services our Cmd+C only after we gave up waiting.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { clipboard.externalWrite("late selection") }
        }
        var timing = SystemTiming.immediate
        timing.lateCopyGrace = 1.5
        let capturer = SelectionCapturer(isAccessibilityGranted: { true }, frontmost: FakeFrontmost(), axReader: FakeAX(.unavailable),
                                         clipboard: clipboard, keys: keys, timing: timing)
        await #expect(throws: CorrectionError.noSelection) { try await capturer.captureSelection() }
        try await Task.sleep(for: .milliseconds(700))
        #expect(clipboard.currentText == "my precious clipboard")
    }
}
