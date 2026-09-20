import Foundation
import Testing
@testable import GrammarAICore

@Suite("CorrectionPipeline - safety ordering and failures")
struct PipelineTests {

    private static let original = "i dont think this is working properly"
    private static let corrected = "I don't think this is working properly."

    private func makePipeline(
        capturer: FakeCapturer? = nil,
        replacer: FakeReplacer,
        confirmer: FakeConfirmer? = nil,
        config: PipelineConfiguration = PipelineConfiguration(),
        log: EventLog,
        events: EventLog = EventLog(),
        reply: @escaping @Sendable (String) async throws -> CorrectionResult = { _ in
            CorrectionResult(correctedText: PipelineTests.corrected, changed: true)
        }
    ) -> CorrectionPipeline {
        CorrectionPipeline(
            capturer: capturer ?? FakeCapturer(text: Self.original, log: log),
            replacer: replacer,
            confirmer: confirmer,
            makeProvider: { FakeProvider(reply: reply, log: log) },
            configuration: { config },
            observer: { event in
                switch event {
                case .correcting: events.add("correcting")
                case .confirming: events.add("confirming")
                case .finished: events.add("finished")
                }
            }
        )
    }

    @Test func happyPathCapturesCorrectsThenReplaces() async {
        let log = EventLog(), events = EventLog()
        let replacer = FakeReplacer(log: log)
        let outcome = await makePipeline(replacer: replacer, log: log, events: events).run()
        #expect(outcome == .replaced)
        #expect(log.events == ["capture", "provider", "replace"])
        #expect(replacer.replacedWith == Self.corrected)
        #expect(events.events == ["correcting", "finished"])
    }

    @Test(arguments: [
        CorrectionError.providerUnavailable("down"), .timeout, .invalidResponse, .emptyResponse,
        .providerNotConfigured("no key")
    ])
    func providerFailureNeverTouchesTheDocument(error: CorrectionError) async {
        let log = EventLog()
        let replacer = FakeReplacer(log: log)
        let outcome = await makePipeline(replacer: replacer, log: log, reply: { _ in throw error }).run()
        #expect(outcome == .failed(error))
        #expect(!log.events.contains("replace"))
        #expect(!log.events.contains("copy"))
    }

    @Test func anEmptyCorrectionIsRejectedBeforeReplacing() async {
        let log = EventLog()
        let outcome = await makePipeline(replacer: FakeReplacer(log: log), log: log, reply: { _ in
            CorrectionResult(correctedText: "   ", changed: true)
        }).run()
        #expect(outcome == .failed(.emptyResponse))
        #expect(!log.events.contains("replace"))
    }

    @Test func aRunawayReplyIsRejectedBeforeReplacing() async {
        let log = EventLog()
        let outcome = await makePipeline(replacer: FakeReplacer(log: log), log: log, reply: { _ in
            CorrectionResult(correctedText: String(repeating: "blah ", count: 200), changed: true)
        }).run()
        #expect(outcome == .failed(.invalidResponse))
        #expect(!log.events.contains("replace"))
    }

    @Test(arguments: [CorrectionError.noSelection, .accessibilityDenied, .secureField])
    func captureFailureSendsNothingToTheProvider(error: CorrectionError) async {
        let log = EventLog(), events = EventLog()
        let outcome = await makePipeline(
            capturer: FakeCapturer(error: error, log: log), replacer: FakeReplacer(log: log), log: log, events: events
        ).run()
        #expect(outcome == .failed(error))
        #expect(log.events == ["capture"])
        #expect(!events.events.contains("correcting"))
    }

    @Test func whitespaceOnlySelectionCountsAsNoSelection() async {
        let log = EventLog()
        let outcome = await makePipeline(
            capturer: FakeCapturer(text: "  \n ", log: log), replacer: FakeReplacer(log: log), log: log
        ).run()
        #expect(outcome == .failed(.noSelection))
        #expect(!log.events.contains("provider"))
    }

    @Test func aVeryLargeSelectionIsRefusedLocally() async {
        let log = EventLog()
        let outcome = await makePipeline(
            capturer: FakeCapturer(text: String(repeating: "a", count: 10_001), log: log),
            replacer: FakeReplacer(log: log), log: log
        ).run()
        #expect(outcome == .failed(.selectionTooLong(limit: 10_000)))
        #expect(!log.events.contains("provider"))
    }

    @Test func alreadyCorrectTextIsLeftAlone() async {
        let log = EventLog()
        let outcome = await makePipeline(replacer: FakeReplacer(log: log), log: log, reply: { text in
            CorrectionResult(correctedText: text, changed: false)
        }).run()
        #expect(outcome == .unchanged)
        #expect(!log.events.contains("replace"))
    }

    @Test func disabledDoesNothingAtAll() async {
        let log = EventLog()
        let outcome = await makePipeline(replacer: FakeReplacer(log: log), config: PipelineConfiguration(isEnabled: false), log: log).run()
        #expect(outcome == .disabled)
        #expect(log.events.isEmpty)
    }

    @Test func replacementFailureIsReported() async {
        let log = EventLog()
        let replacer = FakeReplacer(log: log)
        replacer.outcome = .failure(.replacementFailed)
        #expect(await makePipeline(replacer: replacer, log: log).run() == .failed(.replacementFailed))
    }

    @Test func aDowngradeToTheClipboardIsReported() async {
        let log = EventLog()
        let replacer = FakeReplacer(log: log)
        replacer.outcome = .success(.copiedToClipboard(reason: "You switched apps."))
        #expect(await makePipeline(replacer: replacer, log: log).run() == .copiedToClipboard(reason: "You switched apps."))
    }

    // MARK: Confirmation

    @Test func confirmationCanCancelWithoutTouchingAnything() async {
        let log = EventLog()
        let outcome = await makePipeline(
            replacer: FakeReplacer(log: log), confirmer: FakeConfirmer(decision: .cancel, log: log),
            config: PipelineConfiguration(confirmBeforeReplacing: true), log: log
        ).run()
        #expect(outcome == .failed(.cancelled))
        #expect(log.events == ["capture", "provider", "confirm"])
    }

    @Test func confirmationCanCopyInstead() async {
        let log = EventLog()
        let replacer = FakeReplacer(log: log)
        let outcome = await makePipeline(
            replacer: replacer, confirmer: FakeConfirmer(decision: .copy, log: log),
            config: PipelineConfiguration(confirmBeforeReplacing: true), log: log
        ).run()
        #expect(outcome == .copiedToClipboard(reason: "Copied to clipboard."))
        #expect(replacer.copied == Self.corrected)
        #expect(!log.events.contains("replace"))
    }

    @Test func confirmationIsSkippedUnlessEnabled() async {
        let log = EventLog()
        _ = await makePipeline(replacer: FakeReplacer(log: log), confirmer: FakeConfirmer(decision: .cancel, log: log), log: log).run()
        #expect(!log.events.contains("confirm"))
        #expect(log.events.contains("replace"))
    }

    // MARK: Concurrency

    @Test func aSecondTriggerWhileBusyIsIgnored() async {
        let log = EventLog()
        let pipeline = makePipeline(replacer: FakeReplacer(log: log), log: log, reply: { _ in
            try await Task.sleep(for: .milliseconds(300))
            return CorrectionResult(correctedText: PipelineTests.corrected, changed: true)
        })
        async let first = pipeline.run()
        try? await Task.sleep(for: .milliseconds(80))
        let second = await pipeline.run()
        #expect(second == .busy)
        #expect(await first == .replaced)
        #expect(log.events.filter { $0 == "replace" }.count == 1)
    }

    @Test func cancellingLeavesTheOriginalUntouched() async {
        let log = EventLog()
        let pipeline = makePipeline(replacer: FakeReplacer(log: log), log: log, reply: { _ in
            try await Task.sleep(for: .seconds(5))
            return CorrectionResult(correctedText: PipelineTests.corrected, changed: true)
        })
        async let outcome = pipeline.run()
        try? await Task.sleep(for: .milliseconds(100))
        await pipeline.cancel()
        #expect(await outcome == .failed(.cancelled))
        #expect(!log.events.contains("replace"))
    }

    // MARK: correct(text:)

    @Test func correctTextValidatesWithoutTouchingAnyDocument() async throws {
        let log = EventLog()
        let result = try await makePipeline(replacer: FakeReplacer(log: log), log: log).correct(text: Self.original)
        #expect(result.correctedText == Self.corrected)
        #expect(log.events == ["provider"])
    }

    @Test func correctTextRejectsEmptyInput() async {
        let log = EventLog()
        let pipeline = makePipeline(replacer: FakeReplacer(log: log), log: log)
        await #expect(throws: CorrectionError.noSelection) { try await pipeline.correct(text: " ") }
    }

    @Test func errorMessagesAreTheSpecifiedOnesAndNeverLeakText() {
        #expect(CorrectionError.noSelection.userMessage == "Select some text first.")
        #expect(CorrectionError.accessibilityDenied.userMessage == "Grammar AI needs Accessibility access.")
        #expect(CorrectionError.providerUnavailable("secret detail").userMessage == "Couldn't connect to Claude.")
        #expect(CorrectionError.timeout.userMessage == "Claude took too long to respond.")
        #expect(CorrectionError.invalidResponse.userMessage == "Couldn't understand Claude's response.")
        #expect(CorrectionError.emptyResponse.userMessage == "No correction was returned.")
        #expect(CorrectionError.replacementFailed.userMessage == "Couldn't replace the selected text.")
    }
}
