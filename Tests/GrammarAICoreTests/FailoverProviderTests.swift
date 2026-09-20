import Foundation
import Testing
@testable import GrammarAICore

/// A provider whose behaviour a test scripts, and that counts its calls.
private final class ScriptedProvider: AITextCorrectionProvider, @unchecked Sendable {
    let displayName: String
    private let lock = NSLock()
    private var behaviours: [Result<String, CorrectionError>]
    private(set) var calls = 0

    init(_ name: String, _ behaviours: [Result<String, CorrectionError>]) {
        self.displayName = name
        self.behaviours = behaviours
    }
    convenience init(_ name: String, always: Result<String, CorrectionError>) {
        self.init(name, [always])
    }

    func correct(text: String, context: CorrectionContext) async throws -> CorrectionResult {
        let behaviour: Result<String, CorrectionError> = lock.withLock {
            calls += 1
            return behaviours.count > 1 ? behaviours.removeFirst() : (behaviours.first ?? .failure(.emptyResponse))
        }
        switch behaviour {
        case .success(let text): return CorrectionResult(correctedText: text, changed: true)
        case .failure(let error): throw error
        }
    }
    func checkAvailability() async -> ProviderStatus { .ready(detail: displayName) }
    var callCount: Int { lock.withLock { calls } }
}

@Suite("FailoverProvider")
struct FailoverProviderTests {

    private func chain(_ providers: [(String, AITextCorrectionProvider)], cooldown: TimeInterval = 60,
                       clock: @escaping @Sendable () -> Date = { Date() }) -> FailoverProvider {
        FailoverProvider(links: providers.map { .init(name: $0.0, provider: $0.1) }, cooldown: cooldown, now: clock)
    }

    @Test func usesTheFirstHealthyProvider() async throws {
        let primary = ScriptedProvider("A", always: .success("from A"))
        let backup = ScriptedProvider("B", always: .success("from B"))
        let result = try await chain([("A", primary), ("B", backup)]).correct(text: "hi", context: CorrectionContext())
        #expect(result.correctedText == "from A")
        #expect(backup.callCount == 0)
    }

    @Test func fallsBackWhenTheFirstIsDown() async throws {
        let primary = ScriptedProvider("A", always: .failure(.providerUnavailable("ollama down")))
        let backup = ScriptedProvider("B", always: .success("from B"))
        let result = try await chain([("A", primary), ("B", backup)]).correct(text: "hi", context: CorrectionContext())
        #expect(result.correctedText == "from B")
        #expect(primary.callCount == 1)
        #expect(backup.callCount == 1)
    }

    @Test func fallsBackOnTimeoutAndOnNotConfigured() async throws {
        for outage: CorrectionError in [.timeout, .providerNotConfigured("no ollama")] {
            let primary = ScriptedProvider("A", always: .failure(outage))
            let backup = ScriptedProvider("B", always: .success("from B"))
            let result = try await chain([("A", primary), ("B", backup)]).correct(text: "hi", context: CorrectionContext())
            #expect(result.correctedText == "from B")
        }
    }

    @Test func aBenchedProviderIsSkippedUntilItsCooldownEnds() async throws {
        // A goes down on the first call; the second call should skip straight
        // to B without paying A's timeout again.
        let primary = ScriptedProvider("A", always: .failure(.timeout))
        let backup = ScriptedProvider("B", always: .success("from B"))
        let now = Clock()
        let failover = chain([("A", primary), ("B", backup)], cooldown: 60, clock: now.read)

        _ = try await failover.correct(text: "hi", context: CorrectionContext())
        #expect(primary.callCount == 1)

        now.advance(by: 30) // still within cooldown
        _ = try await failover.correct(text: "hi", context: CorrectionContext())
        #expect(primary.callCount == 1) // A was skipped
        #expect(backup.callCount == 2)
    }

    @Test func aRecoveredProviderIsPreferredAgainAfterCooldown() async throws {
        let primary = ScriptedProvider("A", [.failure(.timeout), .success("A recovered")])
        let backup = ScriptedProvider("B", always: .success("from B"))
        let now = Clock()
        let failover = chain([("A", primary), ("B", backup)], cooldown: 60, clock: now.read)

        _ = try await failover.correct(text: "hi", context: CorrectionContext()) // A fails, B covers
        now.advance(by: 61)
        let result = try await failover.correct(text: "hi", context: CorrectionContext())
        #expect(result.correctedText == "A recovered")
        #expect(backup.callCount == 1) // not needed the second time
    }

    @Test func aBadRequestErrorStopsImmediatelyAndIsNotRetriedElsewhere() async {
        // "Nothing to correct" would fail identically on every provider, and
        // marking A unhealthy for it would be wrong. Surface it at once.
        let primary = ScriptedProvider("A", always: .failure(.emptyResponse))
        let backup = ScriptedProvider("B", always: .success("from B"))
        let failover = chain([("A", primary), ("B", backup)])
        await #expect(throws: CorrectionError.emptyResponse) {
            try await failover.correct(text: "hi", context: CorrectionContext())
        }
        #expect(backup.callCount == 0)
    }

    @Test func anInvalidResponseIsNotRetriedElsewhere() async {
        // A reply that failed the resemblance check is a bad answer, not an
        // outage - the next provider would not necessarily do better and we
        // must not silently paste a second guess.
        let primary = ScriptedProvider("A", always: .failure(.invalidResponse))
        let backup = ScriptedProvider("B", always: .success("from B"))
        let failover = chain([("A", primary), ("B", backup)])
        await #expect(throws: CorrectionError.invalidResponse) {
            try await failover.correct(text: "hi", context: CorrectionContext())
        }
        #expect(backup.callCount == 0)
    }

    @Test func whenEveryProviderIsDownTheFirstOutageIsReported() async {
        let primary = ScriptedProvider("A", always: .failure(.providerNotConfigured("install ollama")))
        let backup = ScriptedProvider("B", always: .failure(.timeout))
        let failover = chain([("A", primary), ("B", backup)])
        await #expect { try await failover.correct(text: "hi", context: CorrectionContext()) } throws: { error in
            if case CorrectionError.providerNotConfigured = error { return true }
            return false
        }
    }

    @Test func aBenchedProviderIsRetriedInTheSameCallRatherThanGivingUp() async throws {
        // The only provider fails its first pass, gets benched, but the
        // second pass retries it anyway - and it has recovered. Refusing to
        // try a benched-but-only provider would be worse than trying it.
        let only = ScriptedProvider("A", [.failure(.timeout), .success("A is back")])
        let now = Clock()
        let failover = chain([("A", only)], cooldown: 3600, clock: now.read)

        let result = try await failover.correct(text: "hi", context: CorrectionContext())
        #expect(result.correctedText == "A is back")
        #expect(only.callCount == 2) // first pass failed, second pass recovered
    }

    @Test func cancellationIsNotTreatedAsAnOutage() async {
        let primary = ScriptedProvider("A", always: .failure(.cancelled))
        let backup = ScriptedProvider("B", always: .success("from B"))
        let failover = chain([("A", primary), ("B", backup)])
        await #expect(throws: CorrectionError.cancelled) {
            try await failover.correct(text: "hi", context: CorrectionContext())
        }
        #expect(backup.callCount == 0)
    }

    @Test func statusReportsReadyWithABackupCount() async {
        let status = await chain([
            ("A", ScriptedProvider("A", always: .success("x"))),
            ("B", ScriptedProvider("B", always: .success("y")))
        ]).checkAvailability()
        #expect(status.isReady)
        #expect(status.detail.contains("backup"))
    }
}

/// A hand-advanced clock, so cooldown logic is tested without real waiting.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 1_000_000
    func advance(by delta: TimeInterval) { lock.withLock { seconds += delta } }
    var read: @Sendable () -> Date { { [self] in Date(timeIntervalSinceReferenceDate: lock.withLock { seconds }) } }
}

@Suite("OllamaProvider")
struct OllamaProviderTests {

    private static func chatResponse(content: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["message": ["role": "assistant", "content": content]] as [String: Any])
    }

    private func provider(model: String = "qwen3:1.7b", transport: FakeTransport) -> OllamaProvider {
        OllamaProvider(model: model, transport: transport)
    }

    @Test func sendsTheRightRequestAndParsesTheReply() async throws {
        let transport = FakeTransport(result: .success((Self.chatResponse(content: #"{"corrected_text":"Hello there.","changed":true}"#), 200)))
        let result = try await provider(transport: transport).correct(text: "helo there", context: CorrectionContext())
        #expect(result.correctedText == "Hello there.")

        let request = try #require(transport.recorder.request)
        #expect(request.url?.absoluteString == "http://localhost:11434/api/chat")
        let httpBody = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        #expect(body["model"] as? String == "qwen3:1.7b")
        #expect(body["think"] as? Bool == false)
        #expect(body["stream"] as? Bool == false)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect((messages.last?["content"] as? String)?.contains("helo there") == true)
    }

    @Test func aMissingModelIsAConfigurationError() async {
        let sut = provider(model: "qwen3:1.7b", transport: FakeTransport(result: .success((Data("{}".utf8), 404))))
        await #expect { try await sut.correct(text: "hi", context: CorrectionContext()) } throws: { error in
            guard case CorrectionError.providerNotConfigured(let message) = error else { return false }
            return message.contains("ollama pull")
        }
    }

    @Test func ollamaNotRunningIsAHelpfulNotConfigured() async {
        let sut = provider(transport: FakeTransport(result: .failure(URLError(.cannotConnectToHost))))
        await #expect { try await sut.correct(text: "hi", context: CorrectionContext()) } throws: { error in
            guard case CorrectionError.providerNotConfigured(let message) = error else { return false }
            return message.lowercased().contains("ollama")
        }
    }

    @Test func anEmptyReplyFromALoadingModelIsEmptyResponse() async {
        let sut = provider(transport: FakeTransport(result: .success((Self.chatResponse(content: "   "), 200))))
        await #expect(throws: CorrectionError.emptyResponse) { try await sut.correct(text: "hi", context: CorrectionContext()) }
    }

    @Test func listsInstalledModels() {
        let data = try! JSONSerialization.data(withJSONObject: ["models": [["name": "qwen3:1.7b"], ["name": "qwen3:4b"]]] as [String: Any])
        #expect(OllamaProvider.installedModels(from: data) == ["qwen3:1.7b", "qwen3:4b"])
    }
}

@Suite("ProviderFactory - free chain")
struct FreeChainFactoryTests {
    @Test func freeProviderBuildsAFailoverChain() {
        let factory = ProviderFactory(keyProvider: FakeKey(key: nil))
        #expect(factory.makeProvider(for: AppSettings(provider: .free)) is FailoverProvider)
        #expect(factory.makeProvider(for: AppSettings(provider: .ollama)) is OllamaProvider)
        #expect(factory.makeProvider(for: AppSettings(provider: .claudeCode)) is ClaudeCodeProvider)
        #expect(factory.makeProvider(for: AppSettings(provider: .anthropicAPI)) is AnthropicAPIProvider)
    }

    @Test func theDefaultProviderIsFreeAndPrivate() {
        #expect(AppSettings().provider == .free)
        #expect(AppSettings().provider.isFree)
    }
}
