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
        switch settings.provider {
        case .free:
            // A free, private chain: the local model first, the Claude Code
            // app as backup so a correction still works if Ollama is not
            // running. If neither is set up, the chain reports that clearly.
            return FailoverProvider(links: [
                Link(name: "Ollama", provider: makeOllama(settings)),
                Link(name: "Claude Code", provider: makeClaudeCode(settings))
            ])
        case .ollama:
            return makeOllama(settings)
        case .claudeCode:
            return makeClaudeCode(settings)
        case .anthropicAPI:
            return AnthropicAPIProvider(
                model: settings.model.resolved(for: .anthropicAPI),
                keyProvider: keyProvider,
                prompt: prompt
            )
        }
    }

    private func makeOllama(_ settings: AppSettings) -> OllamaProvider {
        let model = settings.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return OllamaProvider(
            model: model.isEmpty ? OllamaProvider.defaultModel : model,
            prompt: prompt
        )
    }

    private func makeClaudeCode(_ settings: AppSettings) -> ClaudeCodeProvider {
        let path = settings.claudeExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudeCodeProvider(
            model: settings.model.resolved(for: .claudeCode),
            executablePath: path.isEmpty ? nil : path,
            loadUserSettings: settings.loadClaudeUserSettings,
            prompt: prompt
        )
    }

    private typealias Link = FailoverProvider.Link
}
