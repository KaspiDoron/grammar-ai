import Foundation

/// Corrects text through the user's local Claude Code installation
/// (`claude -p`). Zero setup: it reuses the login Claude Code already has,
/// so no API key is needed.
///
/// Tuned by measurement (docs/RESEARCH.md, section 8): a single model turn
/// at low effort with the CLI's background traffic switched off answers in
/// about 1.4 s. `--json-schema` is deliberately NOT used - it costs a second
/// model turn (7-9 s) - so the JSON reply is parsed by `ResponseValidator`.
public struct ClaudeCodeProvider: AITextCorrectionProvider {

    public let displayName = "Claude Code"

    private let model: ClaudeModel
    private let explicitExecutablePath: String?
    private let loadUserSettings: Bool
    private let timeout: TimeInterval
    private let prompt: CorrectionPrompt
    private let runner: CommandRunning
    private let locator: ClaudeExecutableLocating

    public init(
        model: ClaudeModel = .sonnet,
        executablePath: String? = nil,
        loadUserSettings: Bool = false,
        timeout: TimeInterval = 30,
        prompt: CorrectionPrompt = CorrectionPrompt(),
        runner: CommandRunning = ProcessCommandRunner(),
        locator: ClaudeExecutableLocating = ClaudeExecutableLocator()
    ) {
        self.model = model.resolved(for: .claudeCode)
        self.explicitExecutablePath = executablePath
        self.loadUserSettings = loadUserSettings
        self.timeout = timeout
        self.prompt = prompt
        self.runner = runner
        self.locator = locator
    }

    public func correct(text: String, context: CorrectionContext) async throws -> CorrectionResult {
        guard let executable = locator.locate(explicitPath: explicitExecutablePath) else {
            throw CorrectionError.providerNotConfigured(
                "Claude Code isn't installed. Install it from claude.com/claude-code, or switch to an API key in Settings."
            )
        }

        let nonce = CorrectionPrompt.makeNonce()
        let output: CommandOutput
        do {
            output = try await runner.run(
                executable: executable,
                arguments: Self.arguments(
                    model: model,
                    systemPrompt: prompt.systemPrompt(for: context, nonce: nonce),
                    loadUserSettings: loadUserSettings
                ),
                // stdin, never argv: arguments are visible to every process via `ps`.
                stdin: Data(prompt.userMessage(for: text, nonce: nonce).utf8),
                environment: Self.environment(executable: executable, model: model),
                workingDirectory: Self.neutralWorkingDirectory(),
                timeout: timeout
            )
        } catch CommandError.timedOut {
            throw CorrectionError.timeout
        } catch is CancellationError {
            throw CorrectionError.cancelled
        } catch CommandError.launchFailed {
            // The reason is a localized string that can hold a home-directory
            // path; the log gets a fixed token instead.
            throw CorrectionError.providerUnavailable("launch failed")
        }

        return try Self.parseEnvelope(output)
    }

    public func checkAvailability() async -> ProviderStatus {
        guard let executable = locator.locate(explicitPath: explicitExecutablePath) else {
            return .notConfigured(detail: "Claude Code not found")
        }
        do {
            let output = try await runner.run(
                executable: executable,
                arguments: ["--version"],
                stdin: Data(),
                environment: Self.environment(executable: executable, model: model),
                workingDirectory: Self.neutralWorkingDirectory(),
                timeout: 10
            )
            guard output.exitCode == 0 else {
                return .unavailable(detail: "Claude Code exited with code \(output.exitCode)")
            }
            let version = String(decoding: output.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .ready(detail: version.isEmpty ? "Claude Code found" : version)
        } catch {
            return .unavailable(detail: "Couldn't run Claude Code")
        }
    }

    // MARK: - Invocation

    /// A locked-down, single-shot run: no tools, no MCP servers, no skills,
    /// nothing saved to disk and - unless the user opted in - none of their
    /// Claude Code settings, so no hooks or plugins run. The selection can
    /// only ever be *read* by the model, never acted on.
    static func arguments(model: ClaudeModel, systemPrompt: String, loadUserSettings: Bool) -> [String] {
        var arguments = [
            "-p",
            "--model", model.cliAlias,
            "--output-format", "json",
            "--tools", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-session-persistence",
            // "user" is needed only when Claude Code authenticates through
            // settings (apiKeyHelper, Bedrock, Vertex).
            "--setting-sources", loadUserSettings ? "user" : "",
            "--system-prompt", systemPrompt
        ]
        // A grammar fix needs no deliberation. Haiku has no effort levels;
        // its thinking is switched off through the environment instead.
        if model != .haiku {
            arguments += ["--effort", "low"]
        }
        return arguments
    }

    /// GUI apps get a minimal PATH; give the CLI the usual tool locations.
    /// The switches below turn off the CLI's update check, telemetry and
    /// error reporting for our calls - measured to halve the wall time, and
    /// it means a correction makes exactly one network request.
    static func environment(executable: URL, model: ClaudeModel) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = [
            executable.deletingLastPathComponent().path,
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ]
        let existing = environment["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        var seen = Set<String>()
        environment["PATH"] = (extra + existing).filter { seen.insert($0).inserted }.joined(separator: ":")

        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["DISABLE_TELEMETRY"] = "1"
        environment["DISABLE_ERROR_REPORTING"] = "1"
        if model == .haiku {
            environment["MAX_THINKING_TOKENS"] = "0"
        }
        // When launched from a terminal inside a Claude Code session, do not
        // let that session's markers leak into our one-shot call.
        for key in environment.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_ENTRYPOINT") {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    /// An empty directory of our own, so no project's CLAUDE.md or settings
    /// leak into the request.
    static func neutralWorkingDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("\(AppIdentity.supportDirectoryName)/cli-workdir", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Parsing

    static func parseEnvelope(_ output: CommandOutput) throws -> CorrectionResult {
        let stdout = String(decoding: output.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = stdout.data(using: .utf8), !stdout.isEmpty,
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            if output.exitCode != 0 {
                throw classifyFailure(message: String(decoding: output.stderr, as: UTF8.self), exitCode: output.exitCode)
            }
            throw stdout.isEmpty ? CorrectionError.emptyResponse : CorrectionError.invalidResponse
        }

        let resultText = envelope["result"] as? String ?? ""
        if (envelope["is_error"] as? Bool) == true || output.exitCode != 0 {
            throw classifyFailure(message: resultText, exitCode: output.exitCode)
        }

        if let structured = envelope["structured_output"] as? [String: Any] {
            return try ResponseValidator.result(fromJSONObject: structured)
        }
        return try ResponseValidator.parse(rawResponse: resultText)
    }

    /// Maps a CLI failure to a user-facing error. The CLI's message can hold
    /// anything - a path with the username, an API error body, even model
    /// output - so it is only ever MATCHED against, never forwarded: the log
    /// gets a token from a fixed vocabulary.
    static func classifyFailure(message: String, exitCode: Int32) -> CorrectionError {
        let lowered = message.lowercased()
        let authHints = ["/login", "not logged in", "invalid api key", "authentication", "oauth", "unauthorized"]
        if authHints.contains(where: lowered.contains) {
            return .providerNotConfigured("Claude Code isn't signed in. Open Terminal, run `claude`, and log in.")
        }
        let vocabulary: [(token: String, hints: [String])] = [
            ("rate_limit", ["rate limit", "rate_limit", "429", "usage limit", "limit reached"]),
            ("overloaded", ["overloaded", "529", "503"]),
            ("network", ["network", "enotfound", "econnrefused", "econnreset", "etimedout", "fetch failed", "offline", "socket"]),
            ("model", ["model"])
        ]
        let token = vocabulary.first { $0.hints.contains(where: lowered.contains) }?.token ?? "unknown"
        return .providerUnavailable("exit \(exitCode) \(token)")
    }
}

// MARK: - Locating the binary

public protocol ClaudeExecutableLocating: Sendable {
    func locate(explicitPath: String?) -> URL?
}

public struct ClaudeExecutableLocator: ClaudeExecutableLocating {

    public init() {}

    public func locate(explicitPath: String?) -> URL? {
        let fileManager = FileManager.default
        if let explicitPath, !explicitPath.isEmpty {
            let expanded = (explicitPath as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.npm-global/bin/claude"
        ]
        if let found = candidates.first(where: fileManager.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: found)
        }
        return Self.lookupViaLoginShell()
    }

    /// Last resort for unusual installs: ask the user's login shell. Runs a
    /// fixed command, never anything derived from user text.
    private static func lookupViaLoginShell() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
