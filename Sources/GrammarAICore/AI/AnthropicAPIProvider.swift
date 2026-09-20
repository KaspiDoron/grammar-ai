import Foundation

/// Minimal HTTP seam so the provider is testable without a network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        // Ephemeral: no cookies, no disk cache - request bodies contain the
        // user's text and must never be persisted by the URL loading system.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// Supplies the API key on demand, so the provider never holds a secret
/// longer than one request. The app backs this with the Keychain.
public protocol APIKeyProviding: Sendable {
    func apiKey() -> String?
}

/// Corrects text by calling the Anthropic Messages API directly over HTTPS.
/// Faster than the CLI (no process spawn, single turn) but needs an API key.
///
/// Swift has no official Anthropic SDK, so this is the documented raw-HTTP
/// shape: `POST /v1/messages` with `output_config.format` = `json_schema`.
public struct AnthropicAPIProvider: AITextCorrectionProvider {

    public let displayName = "Anthropic API"

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"

    private let model: ClaudeModel
    private let keyProvider: APIKeyProviding
    private let prompt: CorrectionPrompt
    private let transport: HTTPTransport

    public init(
        model: ClaudeModel = .haiku,
        keyProvider: APIKeyProviding,
        prompt: CorrectionPrompt = CorrectionPrompt(),
        transport: HTTPTransport = URLSessionTransport()
    ) {
        self.model = model.resolved(for: .anthropicAPI)
        self.keyProvider = keyProvider
        self.prompt = prompt
        self.transport = transport
    }

    public func correct(text: String, context: CorrectionContext) async throws -> CorrectionResult {
        guard let key = keyProvider.apiKey(), !key.isEmpty else {
            throw CorrectionError.providerNotConfigured("Add your Anthropic API key in Settings, AI Provider.")
        }

        let nonce = CorrectionPrompt.makeNonce()
        let request = try Self.makeRequest(
            apiKey: key,
            model: model,
            systemPrompt: prompt.systemPrompt(for: context, nonce: nonce),
            userMessage: prompt.userMessage(for: text, nonce: nonce),
            textByteCount: text.utf8.count
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
            // Only the error domain/code reaches the log - never the body.
            let nsError = error as NSError
            throw CorrectionError.providerUnavailable("network: \(nsError.domain) \(nsError.code)")
        }

        guard (200..<300).contains(response.statusCode) else {
            throw Self.classify(status: response.statusCode, body: data)
        }
        return try Self.parseMessage(data)
    }

    public func checkAvailability() async -> ProviderStatus {
        guard let key = keyProvider.apiKey(), !key.isEmpty else {
            return .notConfigured(detail: "No API key saved")
        }
        // Presence check only: validating the key for real would cost a
        // request on every Settings open. The first correction (or the
        // "Test" button) proves it end to end.
        return .ready(detail: "API key saved in Keychain")
    }

    // MARK: - Request

    static func makeRequest(
        apiKey: String,
        model: ClaudeModel,
        systemPrompt: String,
        userMessage: String,
        textByteCount: Int
    ) throws -> URLRequest {
        var outputConfig: [String: Any] = [
            "format": [
                "type": "json_schema",
                "schema": CorrectionPrompt.responseSchema
            ]
        ]
        var body: [String: Any] = [
            "model": model.apiModelID,
            // A correction is about as long as its input. UTF-8 bytes bound
            // the token count from above for every script; add JSON headroom.
            "max_tokens": min(16_000, max(1_024, textByteCount + 512)),
            "system": systemPrompt,
            "messages": [["role": "user", "content": userMessage]]
        ]
        // A grammar fix does not need deliberation and latency is the
        // product. Haiku 4.5 does not think unless asked. Sonnet 5 thinks by
        // default and accepts an explicit opt-out. Opus 5 is documented to
        // misbehave with thinking disabled, so it keeps adaptive thinking at
        // the lowest effort instead.
        switch model {
        case .sonnet:
            body["thinking"] = ["type": "disabled"]
        case .opus:
            outputConfig["effort"] = "low"
        case .haiku, .automatic:
            break
        }
        body["output_config"] = outputConfig

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Response

    static func parseMessage(_ data: Data) throws -> CorrectionResult {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CorrectionError.invalidResponse
        }
        // A refusal or a truncated reply does not match the schema; never
        // try to salvage text out of it.
        let stopReason = message["stop_reason"] as? String
        guard stopReason != "refusal", stopReason != "max_tokens" else {
            throw CorrectionError.invalidResponse
        }
        let blocks = message["content"] as? [[String: Any]] ?? []
        let text = blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CorrectionError.emptyResponse
        }
        return try ResponseValidator.parse(rawResponse: text)
    }

    static func classify(status: Int, body: Data) -> CorrectionError {
        // The API's error `type` is a fixed vocabulary, safe to log.
        let errorType = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
            .flatMap { $0["error"] as? [String: Any] }
            .flatMap { $0["type"] as? String } ?? "unknown"
        switch status {
        case 401, 403:
            return .providerNotConfigured("Anthropic rejected the API key. Check it in Settings, AI Provider.")
        case 408:
            return .timeout
        default:
            return .providerUnavailable("HTTP \(status) \(errorType)")
        }
    }
}
