import Foundation
import Testing
@testable import GrammarAICore

@Suite("OpenAIProvider")
struct OpenAIProviderTests {

    private static func chatResponse(content: String, finish: String = "stop") -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": content], "finish_reason": finish]]
        ] as [String: Any])
    }

    private func provider(key: String? = "sk-test", baseURL: URL = OpenAIProvider.openAIBaseURL, transport: FakeTransport) -> OpenAIProvider {
        OpenAIProvider(model: "gpt-4o-mini", baseURL: baseURL, keyProvider: FakeKey(key: key), transport: transport)
    }

    private func body(of transport: FakeTransport) throws -> [String: Any] {
        let data = try #require(transport.recorder.request?.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func sendsAnOpenAICompatibleRequestAndParsesTheReply() async throws {
        let transport = FakeTransport(result: .success((Self.chatResponse(content: #"{"corrected_text":"Hello there.","changed":true}"#), 200)))
        let result = try await provider(transport: transport).correct(text: "helo there", context: CorrectionContext())
        #expect(result.correctedText == "Hello there.")

        let request = try #require(transport.recorder.request)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer sk-test")
        let body = try body(of: transport)
        #expect(body["model"] as? String == "gpt-4o-mini")
        #expect((body["response_format"] as? [String: Any])?["type"] as? String == "json_object")
    }

    @Test func worksAgainstACustomEndpoint() async throws {
        let groq = URL(string: "https://api.groq.com/openai/v1")!
        let transport = FakeTransport(result: .success((Self.chatResponse(content: #"{"corrected_text":"Hi.","changed":true}"#), 200)))
        _ = try await provider(baseURL: groq, transport: transport).correct(text: "hi", context: CorrectionContext())
        #expect(transport.recorder.request?.url?.absoluteString == "https://api.groq.com/openai/v1/chat/completions")
    }

    @Test func noKeyIsNotConfiguredAndSendsNothing() async {
        let transport = FakeTransport(result: .success((Data(), 200)))
        let sut = provider(key: nil, transport: transport)
        await #expect { try await sut.correct(text: "hi", context: CorrectionContext()) } throws: { error in
            if case CorrectionError.providerNotConfigured = error { return true }
            return false
        }
        #expect(transport.recorder.request == nil)
    }

    @Test(arguments: [401, 403])
    func aRejectedKeyIsNotConfigured(status: Int) async {
        let sut = provider(transport: FakeTransport(result: .success((Data(#"{"error":{"type":"invalid_api_key"}}"#.utf8), status))))
        await #expect { try await sut.correct(text: "hi", context: CorrectionContext()) } throws: { error in
            if case CorrectionError.providerNotConfigured = error { return true }
            return false
        }
    }

    @Test func aTruncatedReplyIsRejected() async {
        let data = Self.chatResponse(content: #"{"corrected_text":"partial"#, finish: "length")
        let sut = provider(transport: FakeTransport(result: .success((data, 200))))
        await #expect(throws: CorrectionError.invalidResponse) { try await sut.correct(text: "hi", context: CorrectionContext()) }
    }

    @Test func factoryBuildsOpenAIAndNormalizesTheBaseURL() {
        let factory = ProviderFactory(keyProvider: FakeKey(key: nil), openAIKeyProvider: FakeKey(key: "k"))
        var settings = AppSettings(provider: .openAI)
        #expect(factory.makeProvider(for: settings) is OpenAIProvider)
        // A base URL without /v1 gets it appended.
        settings.openAIBaseURL = "https://api.groq.com/openai"
        #expect(factory.makeProvider(for: settings) is OpenAIProvider)
    }
}
