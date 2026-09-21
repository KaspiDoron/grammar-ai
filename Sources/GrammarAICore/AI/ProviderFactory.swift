import Foundation

/// Builds the provider the current settings ask for. The rest of the app
/// only ever sees `AITextCorrectionProvider`, so a new integration (OpenAI,
/// Gemini, a local model) is one new provider type plus one case here.
public struct ProviderFactory: Sendable {

    private let keyProvider: APIKeyProviding
    private let openAIKeyProvider: APIKeyProviding
    private let prompt: CorrectionPrompt

    public init(
        keyProvider: APIKeyProviding = KeychainAPIKeyProvider(),
        openAIKeyProvider: APIKeyProviding = KeychainAPIKeyProvider(account: KeychainAPIKeyProvider.openAIAccount),
        prompt: CorrectionPrompt = CorrectionPrompt()
    ) {
        self.keyProvider = keyProvider
        self.openAIKeyProvider = openAIKeyProvider
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
        case .openAI:
            let base = settings.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = settings.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return OpenAIProvider(
                model: model.isEmpty ? OpenAIProvider.defaultModel : model,
                baseURL: URL(string: base).map(Self.normalizedBase) ?? OpenAIProvider.openAIBaseURL,
                keyProvider: openAIKeyProvider,
                prompt: prompt
            )
        }
    }

    /// Accept a base URL with or without a trailing `/v1`, and tolerate a
    /// trailing slash, so users can paste whatever their provider shows.
    private static func normalizedBase(_ url: URL) -> URL {
        var string = url.absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        if !string.hasSuffix("/v1"), !string.contains("/v1/"), !string.hasSuffix("/openai") {
            string += "/v1"
        }
        return URL(string: string) ?? OpenAIProvider.openAIBaseURL
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
