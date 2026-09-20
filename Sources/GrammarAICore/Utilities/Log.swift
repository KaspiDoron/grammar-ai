import Foundation
import os

/// Privacy rule for the whole app: the log NEVER contains text the user
/// selected, text a model returned, or credentials. Only fixed event names
/// and sanitized technical details (status codes, error types, durations).
///
/// Every call site passes a `StaticString`-like event plus an optional
/// sanitized detail, which keeps accidental interpolation of user text out.
public enum Log {

    public enum Category: String, Sendable {
        case app, pipeline, capture, replace, provider, hotkey, settings, services
    }

    public static func info(_ category: Category, _ event: StaticString, detail: String? = nil) {
        let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: category.rawValue)
        if let detail {
            logger.info("\(event.description, privacy: .public): \(detail, privacy: .public)")
        } else {
            logger.info("\(event.description, privacy: .public)")
        }
    }

    public static func error(_ category: Category, _ event: StaticString, detail: String? = nil) {
        let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: category.rawValue)
        if let detail {
            logger.error("\(event.description, privacy: .public): \(detail, privacy: .public)")
        } else {
            logger.error("\(event.description, privacy: .public)")
        }
    }
}
