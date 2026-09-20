import Foundation

public struct CommandOutput: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CommandError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut
}

/// Runs a subprocess. Abstracted so the CLI provider is testable without
/// spawning a real `claude`.
public protocol CommandRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        stdin: Data,
        environment: [String: String],
        workingDirectory: URL,
        timeout: TimeInterval
    ) async throws -> CommandOutput
}

/// `Process`-backed runner. Fully asynchronous: nothing here blocks a thread
/// while the child runs, and the child is killed on timeout or cancellation.
public struct ProcessCommandRunner: CommandRunning {

    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        stdin: Data,
        environment: [String: String],
        workingDirectory: URL,
        timeout: TimeInterval
    ) async throws -> CommandOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let state = RunState()

        // Drain both pipes as data arrives; a child that fills a pipe buffer
        // nobody reads would otherwise hang forever.
        // An empty chunk means end of file.
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { state.markStdoutClosed() } else { state.appendStdout(chunk) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { state.markStderrClosed() } else { state.appendStderr(chunk) }
        }

        // Writing to a child that already exited raises SIGPIPE, which would
        // kill the whole app. With this flag the write fails with EPIPE instead.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandOutput, Error>) in
                process.terminationHandler = { finished in
                    // Let the handlers drain what is still buffered, but only
                    // briefly: a helper the child left behind can hold the
                    // pipe open forever, and waiting for end of file would
                    // then leave this run - and the whole app - stuck.
                    let drainDeadline = Date().addingTimeInterval(0.4)
                    while !state.pipesClosed, Date() < drainDeadline {
                        usleep(5_000)
                    }
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    if state.timedOut {
                        continuation.resume(throwing: CommandError.timedOut)
                    } else if state.cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: CommandOutput(
                            exitCode: finished.terminationStatus,
                            stdout: state.stdout,
                            stderr: state.stderr
                        ))
                    }
                }

                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: CommandError.launchFailed(error.localizedDescription))
                    return
                }

                state.setProcess(process)

                DispatchQueue.global(qos: .userInitiated).async {
                    // Writing can block on a full pipe, so keep it off the caller's thread.
                    try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
                    try? stdinPipe.fileHandleForWriting.close()
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    state.terminate(markTimedOut: true)
                }
            }
        } onCancel: {
            state.terminate(markTimedOut: false)
        }
    }
}

/// Lock-protected scratch state shared between the pipe handlers, the
/// timeout and the cancellation handler.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var _stdout = Data()
    private var _stderr = Data()
    private var _timedOut = false
    private var _cancelled = false
    private var _stdoutClosed = false
    private var _stderrClosed = false
    private var process: Process?

    var pipesClosed: Bool { lock.withLock { _stdoutClosed && _stderrClosed } }
    func markStdoutClosed() { lock.withLock { _stdoutClosed = true } }
    func markStderrClosed() { lock.withLock { _stderrClosed = true } }

    var stdout: Data { lock.withLock { _stdout } }
    var stderr: Data { lock.withLock { _stderr } }
    var timedOut: Bool { lock.withLock { _timedOut } }
    var cancelled: Bool { lock.withLock { _cancelled } }

    func appendStdout(_ data: Data) { lock.withLock { _stdout.append(data) } }
    func appendStderr(_ data: Data) { lock.withLock { _stderr.append(data) } }
    func setProcess(_ process: Process) {
        lock.withLock {
            self.process = process
            // Cancellation may have arrived before the process existed.
            if _cancelled, process.isRunning { process.terminate() }
        }
    }

    func terminate(markTimedOut: Bool) {
        lock.withLock {
            guard let process, process.isRunning else {
                if !markTimedOut { _cancelled = true }
                return
            }
            if markTimedOut { _timedOut = true } else { _cancelled = true }
            process.terminate()
        }
    }
}
