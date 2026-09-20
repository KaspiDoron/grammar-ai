import Foundation

/// Builds the provider the current settings ask for. The rest of the app
/// only ever sees `AITextCorrectionProvider`, so a new integration (OpenAI,
/// Gemini, a local model) is one new provider type plus one case here.
public struct ProviderFactory: Sendable {

    private let keyProvider: APIKeyProviding
    private let prompt: CorrectionPrompt

    public init(
        keyProvider: APIKeyProviding = KeychainAPIKeyProvider(),
        prompt: CorrectionPrompt = CorrectionPrompt()
    ) {
        self.keyProvider = keyProvider
        self.prompt = prompt
    }

    public func makeProvider(for settings: AppSettings) -> AITextCorrectionProvider {
        let model = settings.model.resolved(for: settings.provider)
        switch settings.provider {
        case .claudeCode:
            let path = settings.claudeExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
            return ClaudeCodeProvider(
                model: model,
                executablePath: path.isEmpty ? nil : path,
                loadUserSettings: settings.loadClaudeUserSettings,
                prompt: prompt
            )
        case .anthropicAPI:
            return AnthropicAPIProvider(model: model, keyProvider: keyProvider, prompt: prompt)
        }
    }
}
