import Foundation

/// Snapshot of the settings one run needs. Taken at trigger time so a
/// Settings change mid-run cannot produce a half-old, half-new correction.
public struct PipelineConfiguration: Sendable {
    public var isEnabled: Bool
    public var context: CorrectionContext
    public var confirmBeforeReplacing: Bool
    public var maxSelectionLength: Int

    public init(
        isEnabled: Bool = true,
        context: CorrectionContext = CorrectionContext(),
        confirmBeforeReplacing: Bool = false,
        maxSelectionLength: Int = 10_000
    ) {
        self.isEnabled = isEnabled
        self.context = context
        self.confirmBeforeReplacing = confirmBeforeReplacing
        self.maxSelectionLength = maxSelectionLength
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
        let raw = try await provider.correct(text: text, context: config.context)
        try Task.checkCancellation()
        return try ResponseValidator.validate(raw, against: text, mode: config.context.mode)
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
