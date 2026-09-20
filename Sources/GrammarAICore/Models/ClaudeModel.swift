import Foundation

/// Which Claude model tier corrects the text.
///
/// `automatic` is the default because the fastest tier differs by
/// integration, and latency is the whole product (measured, see
/// docs/RESEARCH.md): through the Claude Code CLI, Sonnet at low effort
/// answers faster than Haiku, which spends tokens thinking; through the API,
/// Haiku without thinking is the quickest.
public enum ClaudeModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case automatic
    case haiku
    case sonnet
    case opus

    public static let defaultModel: ClaudeModel = .automatic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic (fastest)"
        case .haiku: return "Haiku"
        case .sonnet: return "Sonnet"
        case .opus: return "Opus (most capable, slowest)"
        }
    }

    /// The concrete tier to use. Never returns `.automatic`.
    public func resolved(for provider: ProviderKind) -> ClaudeModel {
        guard self == .automatic else { return self }
        switch provider {
        case .claudeCode, .free: return .sonnet
        case .anthropicAPI: return .haiku
        case .ollama: return .haiku // unused (Ollama has its own model id)
        }
    }

    /// Alias understood by the Claude Code CLI (`--model sonnet`). Aliases
    /// track the latest model of a tier, so the app never needs an update
    /// when a new model ships.
    public var cliAlias: String {
        switch self {
        case .automatic, .sonnet: return "sonnet"
        case .haiku: return "haiku"
        case .opus: return "opus"
        }
    }

    /// Model ID for the Anthropic API.
    public var apiModelID: String {
        switch self {
        case .automatic, .haiku: return "claude-haiku-4-5"
        case .sonnet: return "claude-sonnet-5"
        case .opus: return "claude-opus-5"
        }
    }
}
