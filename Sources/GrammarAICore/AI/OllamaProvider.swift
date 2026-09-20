import Foundation

/// Corrects text with a model running locally in Ollama. Completely free,
/// completely private - the text never leaves the Mac - and needs no API
/// key. This is the default first choice in the free failover chain.
///
/// Ollama exposes an OpenAI-ish chat endpoint at `http://localhost:11434`.
/// A small instruct model (qwen3:1.7b) corrects a sentence in a couple of
/// seconds; `think: false` keeps it from spending time reasoning out loud.
public struct OllamaProvider: AITextCorrectionProvider {

    public let displayName = "Ollama (local, free)"

    /// A sensible default; the app lets the user pick from installed models.
    public static let defaultModel = "qwen3:1.7b"
    public static let defaultHost = URL(string: "http://localhost:11434")!

    private let model: String
    private let host: URL
    private let prompt: CorrectionPrompt
    private let transport: HTTPTransport

    public init(
        model: String = OllamaProvider.defaultModel,
        host: URL = OllamaProvider.defaultHost,
        prompt: CorrectionPrompt = CorrectionPrompt(),
        transport: HTTPTransport = URLSessionTransport(timeout: 60)
    ) {
        self.model = model
        self.host = host
        self.prompt = prompt
        self.transport = transport
    }

    public func correct(text: String, context: CorrectionContext) async throws -> CorrectionResult {
        let nonce = CorrectionPrompt.makeNonce()
        let request = try Self.makeRequest(
            host: host,
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
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .cannotFindHost {
            throw CorrectionError.providerNotConfigured(
                "Ollama isn't running. Install it from ollama.com, then run `ollama serve`."
            )
        } catch {
            let nsError = error as NSError
            throw CorrectionError.providerUnavailable("network: \(nsError.domain) \(nsError.code)")
        }

        guard (200..<300).contains(response.statusCode) else {
            // A missing model comes back as 404 with a helpful message.
            if response.statusCode == 404 {
                throw CorrectionError.providerNotConfigured(
                    "Ollama doesn't have the model \"\(model)\". Run `ollama pull \(model)`."
                )
            }
            throw CorrectionError.providerUnavailable("HTTP \(response.statusCode)")
        }
        return try Self.parseResponse(data)
    }

    public func checkAvailability() async -> ProviderStatus {
        // Ask Ollama which models it has: proves the server is up and that
        // our model is present, without spending a generation.
        var request = URLRequest(url: host.appendingPathComponent("api/tags"))
        request.timeoutInterval = 5
        do {
            let (data, response) = try await transport.send(request)
            guard (200..<300).contains(response.statusCode) else {
                return .unavailable(detail: "Ollama returned HTTP \(response.statusCode)")
            }
            let models = Self.installedModels(from: data)
            guard !models.isEmpty else {
                return .notConfigured(detail: "Ollama is running but has no models")
            }
            guard models.contains(where: { $0 == model || $0.hasPrefix("\(model):") || model.hasPrefix("\($0):") }) else {
                return .notConfigured(detail: "Model \"\(model)\" not installed - run `ollama pull \(model)`")
            }
            return .ready(detail: "\(model), local")
        } catch {
            return .notConfigured(detail: "Ollama not running (start it from ollama.com)")
        }
    }

    /// The models Ollama currently has, for the Settings picker.
    public func installedModels() async -> [String] {
        var request = URLRequest(url: host.appendingPathComponent("api/tags"))
        request.timeoutInterval = 5
        guard let (data, response) = try? await transport.send(request),
              (200..<300).contains(response.statusCode) else { return [] }
        return Self.installedModels(from: data)
    }

    // MARK: - Request

    static func makeRequest(host: URL, model: String, systemPrompt: String, userMessage: String) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            // Skip visible chain-of-thought: we want the answer, fast.
            "think": false,
            "options": ["temperature": 0],
            "format": "json",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ]
        ]
        var request = URLRequest(url: host.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Response

    static func parseResponse(_ data: Data) throws -> CorrectionResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CorrectionError.invalidResponse
        }
        // A model still loading, or one that hit its context limit, does not
        // give us a usable message.
        let content = (object["message"] as? [String: Any])?["content"] as? String ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CorrectionError.emptyResponse
        }
        return try ResponseValidator.parse(rawResponse: content)
    }

    static func installedModels(from data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }
    }
}
