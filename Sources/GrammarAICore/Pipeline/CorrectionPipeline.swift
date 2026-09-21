import Foundation

/// Snapshot of the settings one run needs. Taken at trigger time so a
/// Settings change mid-run cannot produce a half-old, half-new correction.
public struct PipelineConfiguration: Sendable {
    public var isEnabled: Bool
    public var context: CorrectionContext
    public var confirmBeforeReplacing: Bool
    /// A hard sanity ceiling. Selections up to here are corrected; larger
    /// than this are refused, to avoid an accidental "select all" on a huge
    /// file turning into thousands of model calls.
    public var maxSelectionLength: Int
    /// Text longer than this is corrected in chunks instead of one call.
    public var chunkThreshold: Int
    /// The largest chunk sent to the model in one call.
    public var maxChunkChars: Int
    /// How many chunks may be in flight at once. Kept at 1 by default: a
    /// local model serves one request at a time, and firing several at once
    /// makes it return empty replies. Cloud providers can raise it.
    public var chunkConcurrency: Int

    public init(
        isEnabled: Bool = true,
        context: CorrectionContext = CorrectionContext(),
        confirmBeforeReplacing: Bool = false,
        maxSelectionLength: Int = 200_000,
        chunkThreshold: Int = 500,
        maxChunkChars: Int = 450,
        chunkConcurrency: Int = 1
    ) {
        self.isEnabled = isEnabled
        self.context = context
        self.confirmBeforeReplacing = confirmBeforeReplacing
        self.maxSelectionLength = maxSelectionLength
        self.chunkThreshold = chunkThreshold
        self.maxChunkChars = maxChunkChars
        self.chunkConcurrency = chunkConcurrency
    }
}

public enum PipelineOutcome: Equatable, Sendable {
    case replaced
    case copiedToClipboard(reason: String)
    /// The text was already correct; nothing was touched.
    case unchanged
    case failed(CorrectionError)
    /// Another correction is still in flight.
    case busy
    case disabled
}

public enum PipelineEvent: Equatable, Sendable {
    case correcting
    /// The model has answered and the user is being asked to confirm.
    case confirming
    case finished(PipelineOutcome)
}

/// The whole product in one place:
///
///     capture -> correct -> validate -> (confirm) -> replace
///
/// The ordering is the safety guarantee: the user's document is only touched
/// in the very last step, after the correction has been parsed and validated.
/// Every failure before that leaves the original text exactly as it was.
public actor CorrectionPipeline {

    private let capturer: TextSelectionCapturing
    private let replacer: TextReplacing & ClipboardWriting
    private let confirmer: CorrectionConfirming?
    private let makeProvider: @Sendable () -> AITextCorrectionProvider
    private let configuration: @Sendable () async -> PipelineConfiguration
    private let observer: @Sendable (PipelineEvent) async -> Void

    private var isRunning = false
    private var currentTask: Task<PipelineOutcome, Never>?

    public init(
        capturer: TextSelectionCapturing,
        replacer: TextReplacing & ClipboardWriting,
        confirmer: CorrectionConfirming? = nil,
        makeProvider: @escaping @Sendable () -> AITextCorrectionProvider,
        configuration: @escaping @Sendable () async -> PipelineConfiguration,
        observer: @escaping @Sendable (PipelineEvent) async -> Void = { _ in }
    ) {
        self.capturer = capturer
        self.replacer = replacer
        self.confirmer = confirmer
        self.makeProvider = makeProvider
        self.configuration = configuration
        self.observer = observer
    }

    /// Runs one correction. `presetSelection` is used when the text was handed
    /// to us (Services menu) instead of captured.
    @discardableResult
    public func run(presetSelection: CapturedSelection? = nil) async -> PipelineOutcome {
        guard !isRunning else { return .busy }
        isRunning = true
        defer {
            isRunning = false
            currentTask = nil
        }

        let task = Task { await self.perform(presetSelection: presetSelection) }
        currentTask = task
        let outcome = await task.value
        await observer(.finished(outcome))
        return outcome
    }

    /// Cancels the in-flight correction, if any. The original text is untouched.
    public func cancel() {
        currentTask?.cancel()
    }

    /// Corrects and validates text that was handed to us (the Services menu,
    /// the onboarding test) without touching any document or the clipboard.
    /// The caller decides what to do with the validated result.
    public func correct(text: String) async throws -> CorrectionResult {
        let config = await configuration()
        return try await Self.correctAndValidate(
            text: text,
            config: config,
            provider: makeProvider()
        )
    }

    private static func correctAndValidate(
        text: String,
        config: PipelineConfiguration,
        provider: AITextCorrectionProvider
    ) async throws -> CorrectionResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CorrectionError.noSelection
        }
        guard text.count <= config.maxSelectionLength else {
            throw CorrectionError.selectionTooLong(limit: config.maxSelectionLength)
        }
        guard TextChunker.needsChunking(text, limit: config.chunkThreshold) else {
            let raw = try await provider.correct(text: text, context: config.context)
            try Task.checkCancellation()
            return try ResponseValidator.validate(raw, against: text, mode: config.context.mode)
        }
        return try await correctInChunks(text: text, config: config, provider: provider)
    }

    /// Corrects a large text piece by piece and stitches it back together.
    ///
    /// Each chunk is corrected and validated on its own. A chunk whose
    /// correction fails to validate (an outage aside) keeps its original text
    /// rather than failing the whole document - one questionable paragraph
    /// must not lose the other forty. A provider outage, or cancellation,
    /// still fails the whole run, because retrying the rest would be pointless.
    private static func correctInChunks(
        text: String,
        config: PipelineConfiguration,
        provider: AITextCorrectionProvider
    ) async throws -> CorrectionResult {
        let chunks = TextChunker.chunks(from: text, maxChunkChars: config.maxChunkChars)
        let separators = chunks.map(\.separator)
        var corrected = Array(repeating: "", count: chunks.count)
        var anyNeedsReview = false

        // Correct chunks with bounded concurrency, preserving order. An
        // outage thrown by any chunk cancels the group and fails the run.
        try await withThrowingTaskGroup(of: (Int, String, Bool).self) { group in
            var next = 0
            var running = 0
            let limit = max(1, config.chunkConcurrency)

            func addTask(_ index: Int) {
                let chunkText = chunks[index].text
                group.addTask {
                    try Task.checkCancellation()
                    // A blank or symbol-only chunk (a code block, a rule) has
                    // nothing to correct; keep it exactly.
                    guard chunkText.contains(where: { $0.isLetter }) else {
                        return (index, chunkText, false)
                    }
                    do {
                        let raw = try await provider.correct(text: chunkText, context: config.context)
                        let result = try ResponseValidator.validate(raw, against: chunkText, mode: config.context.mode)
                        return (index, result.correctedText, result.needsReview)
                    } catch let error as CorrectionError where !error.isOutage {
                        // Bad reply for this chunk only: keep the original.
                        return (index, chunkText, false)
                    }
                }
            }

            while next < chunks.count, running < limit {
                addTask(next); next += 1; running += 1
            }
            while let (index, chunkCorrected, needsReview) = try await group.next() {
                corrected[index] = chunkCorrected
                anyNeedsReview = anyNeedsReview || needsReview
                if next < chunks.count {
                    addTask(next); next += 1
                } else {
                    running -= 1
                }
            }
        }
        try Task.checkCancellation()

        let final = TextChunker.reassemble(correctedTexts: corrected, separators: separators)
        return CorrectionResult(
            correctedText: final,
            changed: final != text,
            needsReview: anyNeedsReview
        )
    }

    private func perform(presetSelection: CapturedSelection?) async -> PipelineOutcome {
        let config = await configuration()
        guard config.isEnabled else { return .disabled }

        do {
            let selection: CapturedSelection
            if let presetSelection {
                selection = presetSelection
            } else {
                selection = try await capturer.captureSelection()
            }

            let original = selection.text
            // Cheap local checks first, so "Correcting..." only ever shows
            // when a request is really about to be sent.
            guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CorrectionError.noSelection
            }
            guard original.count <= config.maxSelectionLength else {
                throw CorrectionError.selectionTooLong(limit: config.maxSelectionLength)
            }

            await observer(.correcting)

            let validated = try await Self.correctAndValidate(
                text: original,
                config: config,
                provider: makeProvider()
            )

            guard validated.changed else { return .unchanged }

            // A rewrite that drifted far from the original is never pasted on
            // trust: the user confirms it, or it goes to the clipboard.
            if validated.needsReview, confirmer == nil {
                await replacer.copyToClipboard(validated.correctedText)
                return .copiedToClipboard(reason: "Big rewrite - copied so you can review it first.")
            }
            if config.confirmBeforeReplacing || validated.needsReview, let confirmer {
                await observer(.confirming)
                switch await confirmer.confirm(original: original, corrected: validated.correctedText) {
                case .replace:
                    break
                case .copy:
                    await replacer.copyToClipboard(validated.correctedText)
                    return .copiedToClipboard(reason: "Copied to clipboard.")
                case .cancel:
                    return .failed(.cancelled)
                }
            }

            // Last exit: a run the user cancelled (from the menu, or while
            // the confirm panel was open) must never reach the document.
            try Task.checkCancellation()

            switch try await replacer.replace(selection: selection, with: validated.correctedText) {
            case .replaced:
                return .replaced
            case .copiedToClipboard(let reason):
                return .copiedToClipboard(reason: reason)
            }
        } catch let error as CorrectionError {
            return .failed(error)
        } catch is CancellationError {
            return .failed(.cancelled)
        } catch {
            return .failed(.providerUnavailable("unexpected: \(type(of: error))"))
        }
    }
}

/// Lets the pipeline offer "copy instead" without knowing about NSPasteboard.
public protocol ClipboardWriting: Sendable {
    func copyToClipboard(_ text: String) async
}
