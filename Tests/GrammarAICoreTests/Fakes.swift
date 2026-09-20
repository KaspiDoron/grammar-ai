import Foundation
@testable import GrammarAICore

/// Records the order things happened in, so tests can assert that the
/// document is only ever touched after validation.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    var events: [String] { lock.withLock { _events } }
    func add(_ event: String) { lock.withLock { _events.append(event) } }
}

struct FakeCapturer: TextSelectionCapturing {
    var result: Result<CapturedSelection, CorrectionError>
    let log: EventLog

    init(text: String, log: EventLog) {
        self.result = .success(CapturedSelection(text: text, source: .accessibility, appBundleID: "test.app", appName: "Test", processID: 1))
        self.log = log
    }
    init(error: CorrectionError, log: EventLog) {
        self.result = .failure(error)
        self.log = log
    }
    func captureSelection() async throws -> CapturedSelection {
        log.add("capture")
        return try result.get()
    }
}

final class FakeReplacer: TextReplacing, ClipboardWriting, @unchecked Sendable {
    let log: EventLog
    var outcome: Result<ReplacementOutcome, CorrectionError> = .success(.replaced)
    private(set) var replacedWith: String?
    private(set) var copied: String?

    init(log: EventLog) { self.log = log }

    func replace(selection: CapturedSelection, with correctedText: String) async throws -> ReplacementOutcome {
        log.add("replace")
        replacedWith = correctedText
        return try outcome.get()
    }
    func copyToClipboard(_ text: String) async {
        log.add("copy")
        copied = text
    }
}

struct FakeProvider: AITextCorrectionProvider {
    let displayName = "Fake"
    var reply: @Sendable (String) async throws -> CorrectionResult
    let log: EventLog

    func correct(text: String, context: CorrectionContext) async throws -> CorrectionResult {
        log.add("provider")
        return try await reply(text)
    }
    func checkAvailability() async -> ProviderStatus { .ready(detail: "fake") }
}

struct FakeConfirmer: CorrectionConfirming {
    let decision: ConfirmationDecision
    let log: EventLog
    func confirm(original: String, corrected: String) async -> ConfirmationDecision {
        log.add("confirm")
        return decision
    }
}

struct FakeCommandRunner: CommandRunning {
    final class Recorder: @unchecked Sendable {
        var arguments: [String] = []
        var stdin = Data()
        var environment: [String: String] = [:]
        var workingDirectory: URL?
    }
    let recorder = Recorder()
    var result: Result<CommandOutput, CommandError>

    func run(executable: URL, arguments: [String], stdin: Data, environment: [String: String],
             workingDirectory: URL, timeout: TimeInterval) async throws -> CommandOutput {
        recorder.arguments = arguments
        recorder.stdin = stdin
        recorder.environment = environment
        recorder.workingDirectory = workingDirectory
        return try result.get()
    }
}

struct FakeLocator: ClaudeExecutableLocating {
    var url: URL? = URL(fileURLWithPath: "/opt/fake/bin/claude")
    func locate(explicitPath: String?) -> URL? { url }
}

struct FakeTransport: HTTPTransport {
    final class Recorder: @unchecked Sendable { var request: URLRequest? }
    let recorder = Recorder()
    var result: Result<(Data, Int), URLError>

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorder.request = request
        let (data, status) = try result.get()
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

struct FakeKey: APIKeyProviding {
    var key: String?
    func apiKey() -> String? { key }
}

func envelope(result: String, isError: Bool = false) -> Data {
    let object: [String: Any] = ["type": "result", "is_error": isError, "result": result]
    return try! JSONSerialization.data(withJSONObject: object)
}
