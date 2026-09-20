import Foundation

/// The AI engine. The app only ever talks to this protocol, so adding an
/// OpenAI / Gemini / local-model provider later is a new file, not a rewrite.
public protocol AITextCorrectionProvider: Sendable {
    /// Short name for the Settings UI, e.g. "Claude Code".
    var displayName: String { get }

    /// Returns the model's correction. The result is NOT yet trusted - the
    /// pipeline validates it before anything touches the user's document.
    func correct(text: String, context: CorrectionContext) async throws -> CorrectionResult

    /// Cheap readiness probe for the Settings status line. Must not send
    /// any user text.
    func checkAvailability() async -> ProviderStatus
}

public enum ProviderStatus: Equatable, Sendable {
    case ready(detail: String)
    case notConfigured(detail: String)
    case unavailable(detail: String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var detail: String {
        switch self {
        case .ready(let detail), .notConfigured(let detail), .unavailable(let detail):
            return detail
        }
    }
}

/// A selection captured from the frontmost app.
public struct CapturedSelection: Equatable, Sendable {
    public enum Source: String, Sendable {
        case accessibility
        case pasteboard
        /// Handed to us by the macOS Services menu.
        case service
    }

    public let text: String
    public let source: Source
    public let appBundleID: String?
    public let appName: String?
    /// The app the text came from. Replacement refuses to paste anywhere else.
    public let processID: Int32?
    /// What Accessibility said about the focused element: `false` means it is
    /// definitely read-only (a web page, a PDF), `nil` means unknown.
    public let isEditable: Bool?
    /// Some code editors copy the whole current line when NOTHING is
    /// selected. Such a capture cannot be told apart from a real selection,
    /// so it is corrected but never pasted: a paste would insert a duplicate
    /// line at the caret.
    public let isAmbiguousLineCopy: Bool

    public init(
        text: String,
        source: Source,
        appBundleID: String?,
        appName: String?,
        processID: Int32? = nil,
        isEditable: Bool? = nil,
        isAmbiguousLineCopy: Bool = false
    ) {
        self.text = text
        self.source = source
        self.appBundleID = appBundleID
        self.appName = appName
        self.processID = processID
        self.isEditable = isEditable
        self.isAmbiguousLineCopy = isAmbiguousLineCopy
    }
}

/// Reads the current selection. Implemented with AX + pasteboard in the app,
/// and with fakes in tests.
public protocol TextSelectionCapturing: Sendable {
    func captureSelection() async throws -> CapturedSelection
}

public enum ReplacementOutcome: Equatable, Sendable {
    /// The correction was pasted over the selection.
    case replaced
    /// Replacing was unsafe (focus moved, selection changed, terminal...), so
    /// the correction was put on the clipboard instead. Original untouched.
    case copiedToClipboard(reason: String)
}

/// Puts validated text back into the user's document.
public protocol TextReplacing: Sendable {
    func replace(selection: CapturedSelection, with correctedText: String) async throws -> ReplacementOutcome
}

/// Optional "confirm before replacing" step.
public enum ConfirmationDecision: Sendable {
    case replace
    case copy
    case cancel
}

public protocol CorrectionConfirming: Sendable {
    func confirm(original: String, corrected: String) async -> ConfirmationDecision
}

/// Where a correction request came from. Automatic mode would be a new
/// trigger that feeds the same pipeline with `requiresConfirmation == true`.
public enum CorrectionTrigger: String, Sendable {
    case hotkey
    case menu
    case service
    case onboardingTest
}
