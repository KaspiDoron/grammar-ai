import Foundation
import GrammarAICore
import Testing
@testable import GrammarAISystem

@Suite("SelectionCapturer")
struct SelectionCapturerTests {

    private func capturer(granted: Bool = true, ax: FakeAX, clipboard: FakeClipboard, keys: FakeKeys) -> SelectionCapturer {
        SelectionCapturer(isAccessibilityGranted: { granted }, frontmost: FakeFrontmost(), axReader: ax,
                          clipboard: clipboard, keys: keys, timing: .immediate)
    }

    @Test func withoutPermissionNothingIsReadOrTyped() async {
        let clipboard = FakeClipboard(text: "mine"), keys = FakeKeys()
        let sut = capturer(granted: false, ax: FakeAX(.text("x", isEditable: true)), clipboard: clipboard, keys: keys)
        await #expect(throws: CorrectionError.accessibilityDenied) { try await sut.captureSelection() }
        #expect(keys.posted.isEmpty)
        #expect(clipboard.log.isEmpty)
    }

    @Test func accessibilityPathNeverTouchesTheClipboardOrKeyboard() async throws {
        let clipboard = FakeClipboard(text: "mine"), keys = FakeKeys()
        let selection = try await capturer(ax: FakeAX(.text("helo wrold", isEditable: true)), clipboard: clipboard, keys: keys).captureSelection()
        #expect(selection.text == "helo wrold")
        #expect(selection.source == .accessibility)
        #expect(selection.processID == 42)
        #expect(selection.isEditable == true)
        #expect(keys.posted.isEmpty)
        #expect(clipboard.log.isEmpty)
        #expect(clipboard.currentText == "mine")
    }

    @Test func passwordFieldsAreNeverRead() async {
        let keys = FakeKeys()
        let sut = capturer(ax: FakeAX(.secureField), clipboard: FakeClipboard(), keys: keys)
        await #expect(throws: CorrectionError.secureField) { try await sut.captureSelection() }
        #expect(keys.posted.isEmpty) // no fallback copy either
    }

    @Test func secureInputModeBlocksEverything() async {
        let keys = FakeKeys()
        keys.isSecureInputActive = true
        let sut = capturer(ax: FakeAX(.text("x", isEditable: true)), clipboard: FakeClipboard(), keys: keys)
        await #expect(throws: CorrectionError.secureField) { try await sut.captureSelection() }
    }

    @Test func fallsBackToCopyAndRestoresTheUsersClipboard() async throws {
        let clipboard = FakeClipboard(text: "my precious clipboard"), keys = FakeKeys()
        keys.onCopy = { clipboard.externalWrite("text from electron app") }
        let selection = try await capturer(ax: FakeAX(.unavailable), clipboard: clipboard, keys: keys).captureSelection()
        #expect(selection.text == "text from electron app")
        #expect(selection.source == .pasteboard)
        #expect(keys.posted == ["copy"])
        #expect(clipboard.currentText == "my precious clipboard")
    }

    @Test func nothingSelectedMeansNoSelectionAndAnUntouchedClipboard() async {
        let clipboard = FakeClipboard(text: "mine"), keys = FakeKeys() // copy changes nothing
        let sut = capturer(ax: FakeAX(.unavailable), clipboard: clipboard, keys: keys)
        await #expect(throws: CorrectionError.noSelection) { try await sut.captureSelection() }
        #expect(clipboard.currentText == "mine")
        #expect(!clipboard.log.contains("restore"))
    }

    @Test func anEditorsWholeLineCopyIsNotASelection() async {
        let clipboard = FakeClipboard(text: "mine"), keys = FakeKeys()
        keys.onCopy = { clipboard.externalWrite("the whole current line\n", emptySelectionCopy: true) }
        let sut = capturer(ax: FakeAX(.unavailable), clipboard: clipboard, keys: keys)
        await #expect(throws: CorrectionError.noSelection) { try await sut.captureSelection() }
        #expect(clipboard.currentText == "mine")
    }
}

@Suite("TextReplacer - never the wrong change")
struct TextReplacerTests {

    private let original = "helo wrold"
    private let corrected = "Hello world"

    private func replacer(granted: Bool = true, frontmost: FakeFrontmost = FakeFrontmost(),
                          ax: FakeAX, clipboard: FakeClipboard, keys: FakeKeys) -> TextReplacer {
        TextReplacer(isAccessibilityGranted: { granted }, frontmost: frontmost, axReader: ax,
                     clipboard: clipboard, keys: keys, timing: .immediate)
    }

    private func selection(source: CapturedSelection.Source = .accessibility, pid: Int32? = 42, editable: Bool? = true) -> CapturedSelection {
        CapturedSelection(text: original, source: source, appBundleID: "com.example.editor", appName: "Editor", processID: pid, isEditable: editable)
    }

    private func expectCopiedNotPasted(_ outcome: ReplacementOutcome, _ clipboard: FakeClipboard, _ keys: FakeKeys) {
        guard case .copiedToClipboard = outcome else {
            Issue.record("expected a downgrade to the clipboard, got \(outcome)")
            return
        }
        #expect(!keys.posted.contains("paste"))
        #expect(clipboard.currentText == corrected)
    }

    @Test func pastesAndRestoresTheClipboard() async throws {
        let clipboard = FakeClipboard(text: "my precious clipboard"), keys = FakeKeys()
        let pasted = Mutex<String?>(nil)
        keys.onPaste = { pasted.set(clipboard.currentText) }
        // Selection still there, then gone once the paste replaced it.
        let ax = FakeAX(.text(original, isEditable: true), .unavailable)
        let outcome = try await replacer(ax: ax, clipboard: clipboard, keys: keys).replace(selection: selection(), with: corrected)
        #expect(outcome == .replaced)
        #expect(pasted.value == corrected)                       // the app saw the correction
        #expect(clipboard.currentText == "my precious clipboard") // and the user got theirs back
        #expect(clipboard.log.contains("writeTransient"))
    }

    @Test func withoutPermissionItThrowsAndTouchesNothing() async {
        let clipboard = FakeClipboard(text: "mine"), keys = FakeKeys()
        let sut = replacer(granted: false, ax: FakeAX(.text(original, isEditable: true)), clipboard: clipboard, keys: keys)
        await #expect(throws: CorrectionError.accessibilityDenied) { try await sut.replace(selection: selection(), with: corrected) }
        #expect(clipboard.currentText == "mine")
    }

    @Test func switchingAppsDowngradesToCopy() async throws {
        let clipboard = FakeClipboard(), keys = FakeKeys()
        let other = FakeFrontmost(app: FrontmostApp(processID: 7, bundleID: "com.other", name: "Other"))
        let outcome = try await replacer(frontmost: other, ax: FakeAX(.text(original, isEditable: true)), clipboard: clipboard, keys: keys)
            .replace(selection: selection(), with: corrected)
        expectCopiedNotPasted(outcome, clipboard, keys)
    }

    @Test(arguments: ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty"])
    func terminalsAreNeverPastedInto(bundleID: String) async throws {
        let clipboard = FakeClipboard(), keys = FakeKeys()
        let terminal = FakeFrontmost(app: FrontmostApp(processID: 42, bundleID: bundleID, name: "Terminal"))
        let outcome = try await replacer(frontmost: terminal, ax: FakeAX(.text(original, isEditable: nil)), clipboard: clipboard, keys: keys)
            .replace(selection: selection(), with: corrected)
        expectCopiedNotPasted(outcome, clipboard, keys)
    }

    @Test func readOnlyTextIsNotPastedInto() async throws {
        let clipboard = FakeClipboard(), keys = FakeKeys()
        let outcome = try await replacer(ax: FakeAX(.text(original, isEditable: false)), clipboard: clipboard, keys: keys)
            .replace(selection: selection(editable: false), with: corrected)
        expectCopiedNotPasted(outcome, clipboard, keys)
    }

    @Test func aChangedSelectionIsNotOverwritten() async throws {
        let clipboard = FakeClipboard(), keys = FakeKeys()
        let outcome = try await replacer(ax: FakeAX(.text("something else entirely", isEditable: true)), clipboard: clipboard, keys: keys)
            .replace(selection: selection(), with: corrected)
        expectCopiedNotPasted(outcome, clipboard, keys)
    }

    @Test func aVanishedSelectionDoesNotGetADuplicatePasted() async throws {
        let clipboard = FakeClipboard(), keys = FakeKeys()
        let outcome = try await replacer(ax: FakeAX(.unavailable), clipboard: clipboard, keys: keys)
            .replace(selection: selection(source: .accessibility), with: corrected)
        expectCopiedNotPasted(outcome, clipboard, keys)
    }

    @Test func aSecureFieldAppearingMeanwhileBlocksThePaste() async throws {
        let clipboard = FakeClipboard(), keys = FakeKeys()
        let outcome = try await replacer(ax: FakeAX(.secureField), clipboard: clipboard, keys: keys)
            .replace(selection: selection(), with: corrected)
        expectCopiedNotPasted(outcome, clipboard, keys)
    }

    @Test func appsInvisibleToAccessibilityAreVerifiedByCopyingAgain() async throws {
        let clipboard = FakeClipboard(text: "mine"), keys = FakeKeys()
        let original = self.original
        keys.onCopy = { clipboard.externalWrite(original) } // still selected
        let outcome = try await replacer(ax: FakeAX(.unavailable), clipboard: clipboard, keys: keys)
            .replace(selection: selection(source: .pasteboard), with: corrected)
        #expect(outcome == .replaced)
        #expect(keys.posted == ["copy", "paste"])
        #expect(clipboard.currentText == "mine")
    }

    @Test func appsInvisibleToAccessibilityAreNotPastedIntoIfTheSelectionMoved() async throws {
        let clipboard = FakeClipboard(text: "mine"), keys = FakeKeys()
        keys.onCopy = { clipboard.externalWrite("the user selected something else") }
        let outcome = try await replacer(ax: FakeAX(.unavailable), clipboard: clipboard, keys: keys)
            .replace(selection: selection(source: .pasteboard), with: corrected)
        expectCopiedNotPasted(outcome, clipboard, keys)
    }

    @Test func aClipboardTheUserChangedMeanwhileIsNotOverwritten() async throws {
        let clipboard = FakeClipboard(text: "old"), keys = FakeKeys()
        keys.onPaste = { clipboard.externalWrite("the user copied this during the paste") }
        let ax = FakeAX(.text(original, isEditable: true), .unavailable)
        _ = try await replacer(ax: ax, clipboard: clipboard, keys: keys).replace(selection: selection(), with: corrected)
        #expect(clipboard.currentText == "the user copied this during the paste")
    }

    @Test func copyToClipboardWritesPlainly() async {
        let clipboard = FakeClipboard()
        await replacer(ax: FakeAX(.unavailable), clipboard: clipboard, keys: FakeKeys()).copyToClipboard("kept")
        #expect(clipboard.currentText == "kept")
        #expect(clipboard.log == ["write"])
    }
}

/// Tiny lock box for values written from a @Sendable closure.
final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.withLock { _value } }
    func set(_ newValue: Value) { lock.withLock { _value = newValue } }
}
