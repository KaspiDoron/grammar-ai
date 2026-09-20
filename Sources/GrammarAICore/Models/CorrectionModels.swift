import Foundation

/// How aggressively the text should be corrected.
public enum CorrectionMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case basic
    case natural
    case professional
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .basic: return "Basic Grammar"
        case .natural: return "Natural"
        case .professional: return "Professional"
        case .custom: return "Custom"
        }
    }

    public var summary: String {
        switch self {
        case .basic: return "Fix only grammar, spelling, punctuation and capitalization."
        case .natural: return "Fix mistakes and smooth awkward sentences, keeping your tone."
        case .professional: return "Make the text clearer and more professional."
        case .custom: return "Follow your own instruction."
        }
    }
}

/// The language the correction should be written in. `automatic` lets the
/// model detect it from the input, so nothing here is English-specific.
public enum CorrectionLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case automatic
    case english = "en"
    case hebrew = "he"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case portuguese = "pt"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .english: return "English"
        case .hebrew: return "Hebrew"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .portuguese: return "Portuguese"
        }
    }

    /// Name used inside the prompt. Nil means "detect it".
    public var promptName: String? {
        self == .automatic ? nil : displayName
    }
}

/// Everything a provider needs to know besides the text itself.
public struct CorrectionContext: Equatable, Sendable {
    public var mode: CorrectionMode
    public var language: CorrectionLanguage
    public var customInstruction: String
    public var preserveTone: Bool
    public var preserveSlang: Bool
    public var preserveEmojis: Bool

    public init(
        mode: CorrectionMode = .natural,
        language: CorrectionLanguage = .automatic,
        customInstruction: String = "",
        preserveTone: Bool = true,
        preserveSlang: Bool = true,
        preserveEmojis: Bool = true
    ) {
        self.mode = mode
        self.language = language
        self.customInstruction = customInstruction
        self.preserveTone = preserveTone
        self.preserveSlang = preserveSlang
        self.preserveEmojis = preserveEmojis
    }
}

/// A validated correction, safe to put back into the user's document.
public struct CorrectionResult: Equatable, Sendable {
    public let correctedText: String
    public let changed: Bool
    /// BCP-47-ish language tag reported by the model, when it gave one.
    public let language: String?
    /// Set by the validator when a rewrite drifted far from the original.
    /// Such a result is never pasted without the user confirming it.
    public let needsReview: Bool

    public init(correctedText: String, changed: Bool, language: String? = nil, needsReview: Bool = false) {
        self.correctedText = correctedText
        self.changed = changed
        self.language = language
        self.needsReview = needsReview
    }
}

/// Every way a correction can fail. Messages are user-facing and never
/// contain the user's text, credentials or raw provider output.
public enum CorrectionError: Error, Equatable, Sendable {
    case noSelection
    case accessibilityDenied
    case secureField
    case selectionTooLong(limit: Int)
    case providerNotConfigured(String)
    case providerUnavailable(String)
    case timeout
    case invalidResponse
    case emptyResponse
    case replacementFailed
    case cancelled

    public var userMessage: String {
        switch self {
        case .noSelection:
            return "Select some text first."
        case .accessibilityDenied:
            return "Grammar AI needs Accessibility access."
        case .secureField:
            return "Grammar AI never reads password fields."
        case .selectionTooLong(let limit):
            return "Selection is too long (limit \(limit) characters)."
        case .providerNotConfigured(let detail):
            return detail
        case .providerUnavailable:
            return "Couldn't connect to Claude."
        case .timeout:
            return "Claude took too long to respond."
        case .invalidResponse:
            return "Couldn't understand Claude's response."
        case .emptyResponse:
            return "No correction was returned."
        case .replacementFailed:
            return "Couldn't replace the selected text."
        case .cancelled:
            return "Cancelled."
        }
    }

    /// Sanitized technical detail for the log - never user text.
    public var logDetail: String {
        switch self {
        case .providerUnavailable(let detail): return "providerUnavailable: \(detail)"
        case .providerNotConfigured(let detail): return "providerNotConfigured: \(detail)"
        default: return String(describing: self)
        }
    }
}
