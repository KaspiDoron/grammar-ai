import Foundation

/// Tries several providers in order until one succeeds. If the first is down,
/// the next covers for it, so a correction keeps working while you sort out
/// whatever broke the preferred one.
///
/// Health is remembered across calls: a provider that just failed with a
/// "the service is down" kind of error is skipped for a cooldown, so the app
/// does not pay its timeout on every keystroke. A provider that fails because
/// the *request* was bad (nothing to correct, a refusal) is not marked
/// unhealthy - retrying it would fail the same way, and so would the next
/// one, so that error is surfaced straight away.
public actor FailoverProvider: AITextCorrectionProvider {

    public nonisolated let displayName = "Automatic (free, with backup)"

    /// One provider in the chain, with a human name for status.
    public struct Link: Sendable {
        public let name: String
        public let provider: AITextCorrectionProvider
        public init(name: String, provider: AITextCorrectionProvider) {
            self.name = name
            self.provider = provider
        }
    }

    private let links: [Link]
    private let cooldown: TimeInterval
    private let now: @Sendable () -> Date
    /// Provider name -> the time it may be tried again.
    private var benchedUntil: [String: Date] = [:]

    public init(
        links: [Link],
        cooldown: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.links = links
        self.cooldown = cooldown
        self.now = now
    }

    public func correct(text: String, context: CorrectionContext) async throws -> CorrectionResult {
        guard !links.isEmpty else {
            throw CorrectionError.providerNotConfigured("No AI provider is configured.")
        }

        var firstOutageError: CorrectionError?
        let currentTime = now()

        // First pass: providers believed healthy, in order.
        for link in links where isHealthy(link.name, at: currentTime) {
            do {
                let result = try await link.provider.correct(text: text, context: context)
                markHealthy(link.name)
                return result
            } catch let error as CorrectionError {
                try handle(error, for: link.name, firstOutage: &firstOutageError)
            }
        }

        // Second pass: everything healthy was down. Try the benched ones too,
        // newest-benched last, in case one has quietly recovered.
        for link in links where !isHealthy(link.name, at: currentTime) {
            do {
                let result = try await link.provider.correct(text: text, context: context)
                markHealthy(link.name)
                return result
            } catch let error as CorrectionError {
                try handle(error, for: link.name, firstOutage: &firstOutageError)
            }
        }

        // Every provider failed with an outage. Report the first one's reason.
        throw firstOutageError ?? .providerUnavailable("all providers unavailable")
    }

    public nonisolated func checkAvailability() async -> ProviderStatus {
        var readyName: String?
        var lastDetail = "no providers"
        for link in links {
            let status = await link.provider.checkAvailability()
            if status.isReady {
                readyName = link.name
                break
            }
            lastDetail = "\(link.name): \(status.detail)"
        }
        if let readyName {
            let backups = links.count - 1
            return .ready(detail: backups > 0 ? "\(readyName) (+\(backups) backup\(backups == 1 ? "" : "s"))" : readyName)
        }
        return .notConfigured(detail: lastDetail)
    }

    /// For the Settings UI: which providers are up right now.
    public nonisolated func statuses() async -> [(name: String, status: ProviderStatus)] {
        var result: [(String, ProviderStatus)] = []
        for link in links {
            result.append((link.name, await link.provider.checkAvailability()))
        }
        return result
    }

    // MARK: - Health

    /// An error that means "this provider is down" (skip it for a while)
    /// rather than "this request was bad" (do not retry anywhere).
    private func isOutage(_ error: CorrectionError) -> Bool {
        switch error {
        case .providerUnavailable, .timeout, .providerNotConfigured:
            return true
        case .noSelection, .accessibilityDenied, .secureField, .selectionTooLong,
             .invalidResponse, .emptyResponse, .replacementFailed, .cancelled:
            return false
        }
    }

    private func handle(_ error: CorrectionError, for name: String, firstOutage: inout CorrectionError?) throws {
        if isOutage(error) {
            bench(name)
            if firstOutage == nil { firstOutage = error }
            return // try the next provider
        }
        if error == .cancelled { throw error }
        // A bad-request error would fail identically everywhere; stop now.
        throw error
    }

    private func isHealthy(_ name: String, at time: Date) -> Bool {
        guard let until = benchedUntil[name] else { return true }
        return time >= until
    }

    private func bench(_ name: String) {
        benchedUntil[name] = now().addingTimeInterval(cooldown)
    }

    private func markHealthy(_ name: String) {
        benchedUntil[name] = nil
    }
}
