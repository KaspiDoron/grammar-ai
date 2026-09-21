import Foundation

/// Corrects text through any OpenAI-compatible chat API. With the default
/// base URL this is OpenAI itself; point `baseURL` at another endpoint and
/// the same provider serves Groq, OpenRouter, DeepSeek, Together, a local
/// vLLM, and so on. The key is read from the Keychain at request time.
///
/// This is a paid, cloud provider: the text leaves the Mac and goes to
/// whichever service the key belongs to.
public struct OpenAIProvider: AITextCorrectionProvider {

    public let displayName: String

    public static let openAIBaseURL = URL(string: "https://api.openai.com/v1")!
    public static let defaultModel = "gpt-4o-mini"

    private let model: String
    private let baseURL: URL
    private let keyProvider: APIKeyProviding
    private let prompt: CorrectionPrompt
    private let transport: HTTPTransport

    public init(
        model: String = OpenAIProvider.defaultModel,
        baseURL: URL = OpenAIProvider.openAIBaseURL,
        keyProvider: APIKeyProviding,
        displayName: String = "OpenAI-compatible API",
        prompt: CorrectionPrompt = CorrectionPrompt(),
        transport: HTTPTransport = URLSessionTransport(timeout: 30)
    ) {
        self.model = model
        self.baseURL = baseURL
        self.keyProvider = keyProvider
        self.displayName = displayName
        self.prompt = prompt
        self.transport = transport
    }

    public func correct(text: String, context: CorrectionContext) async throws -> CorrectionResult {
        guard let key = keyProvider.apiKey(), !key.isEmpty else {
            throw CorrectionError.providerNotConfigured("Add your API key in Settings, AI Provider.")
        }
        let nonce = CorrectionPrompt.makeNonce()
        let request = try Self.makeRequest(
            baseURL: baseURL,
            apiKey: key,
            model: model,
            systemPrompt: prompt.systemPrompt(for: context, nonce: nonce),
            userMessage: prompt.userMessage(for: text, nonce: nonce)
        )

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError where error.code == .timedOut {
            throw CorrectionError.timeout
        } catch let error as URLError where error.code == .cancelled {
            throw CorrectionError.cancelled
        } catch is CancellationError {
            throw CorrectionError.cancelled
        } catch {
            let nsError = error as NSError
            throw CorrectionError.providerUnavailable("network: \(nsError.domain) \(nsError.code)")
        }

        guard (200..<300).contains(response.statusCode) else {
            throw Self.classify(status: response.statusCode, body: data)
        }
        return try Self.parseResponse(data)
    }

    public func checkAvailability() async -> ProviderStatus {
        guard let key = keyProvider.apiKey(), !key.isEmpty else {
            return .notConfigured(detail: "No API key saved")
        }
        return .ready(detail: "\(model) - key in Keychain")
    }

    // MARK: - Request

    static func makeRequest(baseURL: URL, apiKey: String, model: String, systemPrompt: String, userMessage: String) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            // Every OpenAI-compatible server honours this; it asks for a JSON
            // object back, which is what our validator expects.
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ]
        ]
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Response

    static func parseResponse(_ data: Data) throws -> CorrectionResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first else {
            throw CorrectionError.invalidResponse
        }
        // A cut-off reply (length) or a content filter is not a correction.
        if let reason = first["finish_reason"] as? String, reason != "stop", reason != "" {
            if reason == "length" || reason == "content_filter" {
                throw CorrectionError.invalidResponse
            }
        }
        let content = (first["message"] as? [String: Any])?["content"] as? String ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CorrectionError.emptyResponse
        }
        return try ResponseValidator.parse(rawResponse: content)
    }

    static func classify(status: Int, body: Data) -> CorrectionError {
        let errorType = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
            .flatMap { $0["error"] as? [String: Any] }
            .flatMap { $0["type"] as? String ?? $0["code"] as? String } ?? "unknown"
        switch status {
        case 401, 403:
            return .providerNotConfigured("The API rejected your key. Check it in Settings, AI Provider.")
        case 429:
            return .providerUnavailable("rate limited")
        case 408:
            return .timeout
        default:
            return .providerUnavailable("HTTP \(status) \(errorType)")
        }
    }
}
