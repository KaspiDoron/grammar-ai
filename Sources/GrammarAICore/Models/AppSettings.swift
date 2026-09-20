import Foundation

/// Which AI engine performs the correction.
public enum ProviderKind: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Free, automatic, with a backup: a local Ollama model first, and if it
    /// is not running, the Claude Code app. Nothing to pay, nothing to break
    /// a correction if one engine is down. The default.
    case free
    /// A local model in Ollama only. Free and fully private.
    case ollama
    /// The user's local Claude Code install (`claude -p`). No API key.
    case claudeCode
    /// Direct HTTPS calls to the Anthropic API with a key from the Keychain.
    case anthropicAPI

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .free: return "Free (automatic)"
        case .ollama: return "Ollama (local, free)"
        case .claudeCode: return "Claude Code"
        case .anthropicAPI: return "Anthropic API key"
        }
    }

    public var summary: String {
        switch self {
        case .free:
            return "Free and private: a local model first, and the Claude Code app as backup if it isn't running. Recommended."
        case .ollama:
            return "A model running locally in Ollama. Free, private, and your text never leaves this Mac."
        case .claudeCode:
            return "Uses the Claude Code app already signed in on this Mac. No API key needed."
        case .anthropicAPI:
            return "Calls the Anthropic API directly. Fastest, needs your own API key."
        }
    }

    /// Providers that cost nothing to run.
    public var isFree: Bool {
        self == .free || self == .ollama || self == .claudeCode
    }
}

/// Every user preference. Persisted as one JSON value so a save is atomic
/// and a run can snapshot a consistent set of settings.
///
/// Secrets are NOT in here - the API key lives only in the Keychain.
/// "Launch at login" is not in here either: macOS owns that state and the
/// app reads it live from `SMAppService`.
public struct AppSettings: Codable, Equatable, Sendable {

    // General
    public var isEnabled: Bool
    public var hotkey: KeyCombo?
    public var showNotifications: Bool
    public var confirmBeforeReplacing: Bool

    // Correction
    public var mode: CorrectionMode
    public var language: CorrectionLanguage
    public var customInstruction: String
    public var preserveTone: Bool
    public var preserveSlang: Bool
    public var preserveEmojis: Bool

    // AI provider
    public var provider: ProviderKind
    public var model: ClaudeModel
    /// The Ollama model used by the free/local providers.
    public var ollamaModel: String
    /// Optional override for where `claude` lives. Empty means auto-detect.
    public var claudeExecutablePath: String
    /// Off by default: the CLI then ignores the user's Claude Code settings,
    /// so no hooks or plugins run. Turn on only if Claude Code authenticates
    /// through settings (apiKeyHelper, Bedrock, Vertex).
    public var loadClaudeUserSettings: Bool

    // State
    public var hasCompletedOnboarding: Bool

    public init(
        isEnabled: Bool = true,
        hotkey: KeyCombo? = .defaultCorrection,
        showNotifications: Bool = true,
        confirmBeforeReplacing: Bool = false,
        mode: CorrectionMode = .natural,
        language: CorrectionLanguage = .automatic,
        customInstruction: String = "",
        preserveTone: Bool = true,
        preserveSlang: Bool = true,
        preserveEmojis: Bool = true,
        provider: ProviderKind = .free,
        model: ClaudeModel = .defaultModel,
        ollamaModel: String = OllamaProvider.defaultModel,
        claudeExecutablePath: String = "",
        loadClaudeUserSettings: Bool = false,
        hasCompletedOnboarding: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.hotkey = hotkey
        self.showNotifications = showNotifications
        self.confirmBeforeReplacing = confirmBeforeReplacing
        self.mode = mode
        self.language = language
        self.customInstruction = customInstruction
        self.preserveTone = preserveTone
        self.preserveSlang = preserveSlang
        self.preserveEmojis = preserveEmojis
        self.provider = provider
        self.model = model
        self.ollamaModel = ollamaModel
        self.claudeExecutablePath = claudeExecutablePath
        self.loadClaudeUserSettings = loadClaudeUserSettings
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    /// Tolerant decoding: a field added in a later version (or removed by a
    /// downgrade) falls back to its default instead of wiping every setting.
    public init(from decoder: Decoder) throws {
        let defaults = AppSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }

        isEnabled = value(.isEnabled, defaults.isEnabled)
        // An explicit null means "the user cleared the shortcut"; only a
        // missing key falls back to the default.
        if container.contains(.hotkey) {
            hotkey = try? container.decodeIfPresent(KeyCombo.self, forKey: .hotkey)
        } else {
            hotkey = defaults.hotkey
        }
        showNotifications = value(.showNotifications, defaults.showNotifications)
        confirmBeforeReplacing = value(.confirmBeforeReplacing, defaults.confirmBeforeReplacing)
        mode = value(.mode, defaults.mode)
        language = value(.language, defaults.language)
        customInstruction = value(.customInstruction, defaults.customInstruction)
        preserveTone = value(.preserveTone, defaults.preserveTone)
        preserveSlang = value(.preserveSlang, defaults.preserveSlang)
        preserveEmojis = value(.preserveEmojis, defaults.preserveEmojis)
        provider = value(.provider, defaults.provider)
        model = value(.model, defaults.model)
        ollamaModel = value(.ollamaModel, defaults.ollamaModel)
        claudeExecutablePath = value(.claudeExecutablePath, defaults.claudeExecutablePath)
        loadClaudeUserSettings = value(.loadClaudeUserSettings, defaults.loadClaudeUserSettings)
        hasCompletedOnboarding = value(.hasCompletedOnboarding, defaults.hasCompletedOnboarding)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        // Encode nil explicitly so "cleared" survives a round trip.
        try container.encode(hotkey, forKey: .hotkey)
        try container.encode(showNotifications, forKey: .showNotifications)
        try container.encode(confirmBeforeReplacing, forKey: .confirmBeforeReplacing)
        try container.encode(mode, forKey: .mode)
        try container.encode(language, forKey: .language)
        try container.encode(customInstruction, forKey: .customInstruction)
        try container.encode(preserveTone, forKey: .preserveTone)
        try container.encode(preserveSlang, forKey: .preserveSlang)
        try container.encode(preserveEmojis, forKey: .preserveEmojis)
        try container.encode(provider, forKey: .provider)
        try container.encode(model, forKey: .model)
        try container.encode(ollamaModel, forKey: .ollamaModel)
        try container.encode(claudeExecutablePath, forKey: .claudeExecutablePath)
        try container.encode(loadClaudeUserSettings, forKey: .loadClaudeUserSettings)
        try container.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, hotkey, showNotifications, confirmBeforeReplacing
        case mode, language, customInstruction, preserveTone, preserveSlang, preserveEmojis
        case provider, model, ollamaModel, claudeExecutablePath, loadClaudeUserSettings
        case hasCompletedOnboarding
    }

    // MARK: - Derived

    public var correctionContext: CorrectionContext {
        CorrectionContext(
            mode: mode,
            language: language,
            customInstruction: customInstruction,
            preserveTone: preserveTone,
            preserveSlang: preserveSlang,
            preserveEmojis: preserveEmojis
        )
    }

    public var pipelineConfiguration: PipelineConfiguration {
        PipelineConfiguration(
            isEnabled: isEnabled,
            context: correctionContext,
            confirmBeforeReplacing: confirmBeforeReplacing
        )
    }
}

// MARK: - Persistence

public protocol SettingsPersisting: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

/// `UserDefaults`-backed store. Holds preferences only - never text the user
/// corrected, and never credentials.
public final class UserDefaultsSettingsStore: SettingsPersisting, @unchecked Sendable {
    // UserDefaults is documented thread-safe; the class adds no state of its own.
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "settings.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
