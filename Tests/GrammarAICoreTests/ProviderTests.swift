import Foundation
import Testing
@testable import GrammarAICore

@Suite("ClaudeCodeProvider")
struct ClaudeCodeProviderTests {

    private static let reply = #"{"corrected_text": "Hello there.", "changed": true, "language": "en"}"#

    private func provider(
        model: ClaudeModel = .automatic, loadUserSettings: Bool = false,
        runner: FakeCommandRunner, locator: FakeLocator = FakeLocator()
    ) -> ClaudeCodeProvider {
        ClaudeCodeProvider(model: model, loadUserSettings: loadUserSettings, runner: runner, locator: locator)
    }

    @Test func runsLockedDownAndKeepsTheTextOutOfTheArguments() async throws {
        let runner = FakeCommandRunner(result: .success(CommandOutput(exitCode: 0, stdout: envelope(result: Self.reply), stderr: Data())))
        let result = try await provider(runner: runner).correct(text: "helo there SECRET-TEXT", context: CorrectionContext())
        #expect(result.correctedText == "Hello there.")

        let arguments = runner.recorder.arguments
        for flag in ["-p", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence"] {
            #expect(arguments.contains(flag), "missing \(flag)")
        }
        #expect(arguments.firstIndex(of: "--tools").map { arguments[$0 + 1] } == "")
        #expect(arguments.firstIndex(of: "--setting-sources").map { arguments[$0 + 1] } == "")
        #expect(arguments.firstIndex(of: "--model").map { arguments[$0 + 1] } == "sonnet")
        #expect(arguments.firstIndex(of: "--effort").map { arguments[$0 + 1] } == "low")
        // The slow second model turn must stay off.
        #expect(!arguments.contains("--json-schema"))
        // Arguments are visible in `ps`; the selection travels on stdin only.
        #expect(!arguments.joined(separator: " ").contains("SECRET-TEXT"))
        #expect(String(decoding: runner.recorder.stdin, as: UTF8.self).contains("SECRET-TEXT"))
    }

    @Test func switchesOffBackgroundTrafficAndKeepsAUsablePath() async throws {
        let runner = FakeCommandRunner(result: .success(CommandOutput(exitCode: 0, stdout: envelope(result: Self.reply), stderr: Data())))
        _ = try await provider(runner: runner).correct(text: "helo", context: CorrectionContext())
        let environment = runner.recorder.environment
        #expect(environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")
        #expect(environment["DISABLE_TELEMETRY"] == "1")
        #expect(environment["DISABLE_AUTOUPDATER"] == "1")
        #expect(environment["PATH"]?.contains("/opt/fake/bin") == true)
        #expect(environment["MAX_THINKING_TOKENS"] == nil)
    }

    @Test func haikuGetsThinkingDisabledInsteadOfAnEffortFlag() async throws {
        let runner = FakeCommandRunner(result: .success(CommandOutput(exitCode: 0, stdout: envelope(result: Self.reply), stderr: Data())))
        _ = try await provider(model: .haiku, runner: runner).correct(text: "helo", context: CorrectionContext())
        #expect(!runner.recorder.arguments.contains("--effort"))
        #expect(runner.recorder.environment["MAX_THINKING_TOKENS"] == "0")
    }

    @Test func userSettingsAreLoadedOnlyWhenAskedFor() async throws {
        let runner = FakeCommandRunner(result: .success(CommandOutput(exitCode: 0, stdout: envelope(result: Self.reply), stderr: Data())))
        _ = try await provider(loadUserSettings: true, runner: runner).correct(text: "helo", context: CorrectionContext())
        let arguments = runner.recorder.arguments
        #expect(arguments.firstIndex(of: "--setting-sources").map { arguments[$0 + 1] } == "user")
    }

    @Test func acceptsAFencedReply() async throws {
        let fenced = "```json\n\(Self.reply)\n```"
        let runner = FakeCommandRunner(result: .success(CommandOutput(exitCode: 0, stdout: envelope(result: fenced), stderr: Data())))
        #expect(try await provider(runner: runner).correct(text: "helo", context: CorrectionContext()).correctedText == "Hello there.")
    }

    @Test func missingClaudeIsANotConfiguredError() async {
        let runner = FakeCommandRunner(result: .failure(.timedOut))
        let sut = provider(runner: runner, locator: FakeLocator(url: nil))
        await #expect { try await sut.correct(text: "helo", context: CorrectionContext()) } throws: { error in
            if case CorrectionError.providerNotConfigured = error { return true }
            return false
        }
        #expect(await sut.checkAvailability() == .notConfigured(detail: "Claude Code not found"))
    }

    @Test func timeoutIsReportedAsTimeout() async {
        let sut = provider(runner: FakeCommandRunner(result: .failure(.timedOut)))
        await #expect(throws: CorrectionError.timeout) { try await sut.correct(text: "helo", context: CorrectionContext()) }
    }

    @Test func launchFailureIsUnavailable() async {
        let sut = provider(runner: FakeCommandRunner(result: .failure(.launchFailed("nope"))))
        await #expect { try await sut.correct(text: "helo", context: CorrectionContext()) } throws: { error in
            if case CorrectionError.providerUnavailable = error { return true }
            return false
        }
    }

    @Test func notLoggedInAsksTheUserToSignIn() async {
        let output = CommandOutput(exitCode: 1, stdout: envelope(result: "Invalid API key · Please run /login", isError: true), stderr: Data())
        let sut = provider(runner: FakeCommandRunner(result: .success(output)))
        await #expect { try await sut.correct(text: "helo", context: CorrectionContext()) } throws: { error in
            guard case CorrectionError.providerNotConfigured(let message) = error else { return false }
            return message.contains("signed in")
        }
    }

    @Test func garbageOutputIsInvalidAndEmptyOutputIsEmpty() async {
        let garbage = provider(runner: FakeCommandRunner(result: .success(CommandOutput(exitCode: 0, stdout: Data("<html>".utf8), stderr: Data()))))
        await #expect(throws: CorrectionError.invalidResponse) { try await garbage.correct(text: "helo", context: CorrectionContext()) }

        let empty = provider(runner: FakeCommandRunner(result: .success(CommandOutput(exitCode: 0, stdout: Data(), stderr: Data()))))
        await #expect(throws: CorrectionError.emptyResponse) { try await empty.correct(text: "helo", context: CorrectionContext()) }
    }

    @Test func failureDetailsAreTruncatedForTheLog() {
        let error = ClaudeCodeProvider.classifyFailure(message: String(repeating: "x", count: 1000), exitCode: 2)
        #expect(error.logDetail.count < 220)
    }

    @Test func availabilityReportsTheVersion() async {
        let runner = FakeCommandRunner(result: .success(CommandOutput(exitCode: 0, stdout: Data("2.1.278 (Claude Code)\n".utf8), stderr: Data())))
        #expect(await provider(runner: runner).checkAvailability() == .ready(detail: "2.1.278 (Claude Code)"))
        #expect(runner.recorder.arguments == ["--version"])
    }
}

@Suite("AnthropicAPIProvider")
struct AnthropicAPIProviderTests {

    private static func message(text: String, stopReason: String = "end_turn") -> Data {
        let object: [String: Any] = ["type": "message", "stop_reason": stopReason, "content": [["type": "text", "text": text]]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func provider(model: ClaudeModel = .automatic, key: String? = "sk-ant-test", transport: FakeTransport) -> AnthropicAPIProvider {
        AnthropicAPIProvider(model: model, keyProvider: FakeKey(key: key), transport: transport)
    }

    private func body(of transport: FakeTransport) throws -> [String: Any] {
        let data = try #require(transport.recorder.request?.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func sendsTheDocumentedRequestShape() async throws {
        let transport = FakeTransport(result: .success((Self.message(text: #"{"corrected_text":"Hello there.","changed":true}"#), 200)))
        let result = try await provider(transport: transport).correct(text: "helo there", context: CorrectionContext())
        #expect(result.correctedText == "Hello there.")

        let request = try #require(transport.recorder.request)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

        let body = try body(of: transport)
        #expect(body["model"] as? String == "claude-haiku-4-5")
        #expect(body["thinking"] == nil)
        let format = try #require((body["output_config"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(body["temperature"] == nil) // rejected by current models
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect((messages.first?["content"] as? String)?.contains("helo there") == true)
    }

    @Test func tunesThinkingPerModel() async throws {
        let ok = Self.message(text: #"{"corrected_text":"Hi.","changed":true}"#)

        let sonnet = FakeTransport(result: .success((ok, 200)))
        _ = try await provider(model: .sonnet, transport: sonnet).correct(text: "hi", context: CorrectionContext())
        #expect((try body(of: sonnet)["thinking"] as? [String: Any])?["type"] as? String == "disabled")

        let opus = FakeTransport(result: .success((ok, 200)))
        _ = try await provider(model: .opus, transport: opus).correct(text: "hi", context: CorrectionContext())
        let opusBody = try body(of: opus)
        #expect(opusBody["thinking"] == nil)
        #expect((opusBody["output_config"] as? [String: Any])?["effort"] as? String == "low")
    }

    @Test func noKeyMeansNoRequest() async {
        let transport = FakeTransport(result: .success((Data(), 200)))
        let sut = provider(key: nil, transport: transport)
        await #expect { try await sut.correct(text: "hi", context: CorrectionContext()) } throws: { error in
            if case CorrectionError.providerNotConfigured = error { return true }
            return false
        }
        #expect(transport.recorder.request == nil)
        #expect(await sut.checkAvailability() == .notConfigured(detail: "No API key saved"))
    }

    @Test(arguments: [401, 403])
    func aRejectedKeyIsNotConfigured(status: Int) async {
        let sut = provider(transport: FakeTransport(result: .success((Data(#"{"type":"error","error":{"type":"authentication_error"}}"#.utf8), status))))
        await #expect { try await sut.correct(text: "hi", context: CorrectionContext()) } throws: { error in
            if case CorrectionError.providerNotConfigured = error { return true }
            return false
        }
    }

    @Test(arguments: [429, 500, 529])
    func serverTroubleIsUnavailableAndLogsOnlyTheErrorType(status: Int) async {
        let body = Data(#"{"type":"error","error":{"type":"overloaded_error","message":"user text might be echoed here"}}"#.utf8)
        let sut = provider(transport: FakeTransport(result: .success((body, status))))
        await #expect { try await sut.correct(text: "hi", context: CorrectionContext()) } throws: { error in
            guard case CorrectionError.providerUnavailable(let detail) = error else { return false }
            return detail.contains("overloaded_error") && !detail.contains("echoed")
        }
    }

    @Test(arguments: ["refusal", "max_tokens"])
    func refusalsAndTruncationsAreNeverPasted(stopReason: String) async {
        let data = Self.message(text: #"{"corrected_text":"partial"#, stopReason: stopReason)
        let sut = provider(transport: FakeTransport(result: .success((data, 200))))
        await #expect(throws: CorrectionError.invalidResponse) { try await sut.correct(text: "hi", context: CorrectionContext()) }
    }

    @Test func emptyContentIsEmptyResponse() async {
        let data = try! JSONSerialization.data(withJSONObject: ["stop_reason": "end_turn", "content": []] as [String: Any])
        let sut = provider(transport: FakeTransport(result: .success((data, 200))))
        await #expect(throws: CorrectionError.emptyResponse) { try await sut.correct(text: "hi", context: CorrectionContext()) }
    }

    @Test func networkTimeoutIsTimeoutAndOfflineIsUnavailable() async {
        let slow = provider(transport: FakeTransport(result: .failure(URLError(.timedOut))))
        await #expect(throws: CorrectionError.timeout) { try await slow.correct(text: "hi", context: CorrectionContext()) }

        let offline = provider(transport: FakeTransport(result: .failure(URLError(.notConnectedToInternet))))
        await #expect { try await offline.correct(text: "hi", context: CorrectionContext()) } throws: { error in
            if case CorrectionError.providerUnavailable = error { return true }
            return false
        }
    }

    @Test func maxTokensScalesWithTheInputButIsBounded() throws {
        func maxTokens(_ bytes: Int) throws -> Int {
            let request = try AnthropicAPIProvider.makeRequest(apiKey: "k", model: .haiku, systemPrompt: "s", userMessage: "u", textByteCount: bytes)
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try #require(body["max_tokens"] as? Int)
        }
        #expect(try maxTokens(10) == 1_024)
        #expect(try maxTokens(5_000) == 5_512)
        #expect(try maxTokens(1_000_000) == 16_000)
    }
}

@Suite("ProviderFactory")
struct ProviderFactoryTests {
    @Test func buildsTheProviderTheSettingsAskFor() {
        let factory = ProviderFactory(keyProvider: FakeKey(key: nil))
        var settings = AppSettings()
        settings.provider = .claudeCode
        #expect(factory.makeProvider(for: settings) is ClaudeCodeProvider)
        settings.provider = .anthropicAPI
        #expect(factory.makeProvider(for: settings) is AnthropicAPIProvider)
    }
}
