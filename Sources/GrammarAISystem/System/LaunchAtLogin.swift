import Foundation
import GrammarAICore
import ServiceManagement

/// Launch at login through `SMAppService` (macOS 13+).
///
/// macOS owns this state - the user can flip it in System Settings > General
/// > Login Items at any time - so it is always read live and never cached or
/// stored in our own preferences.
public enum LaunchAtLogin {

    public enum State: Equatable, Sendable {
        case enabled
        case disabled
        /// Registered, but the user must allow it in System Settings.
        case requiresApproval
        /// Not running from an app bundle (for example `swift run`).
        case unavailable
    }

    public static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        // macOS also reports notFound for a real app bundle that was never
        // registered, so availability is decided by the bundle, not by this.
        case .notFound: return isRunningFromAppBundle ? .disabled : .unavailable
        @unknown default: return isRunningFromAppBundle ? .disabled : .unavailable
        }
    }

    private static var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    public static func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status != .notRegistered else { return }
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let nsError = error as NSError
            Log.error(.settings, "launch at login change failed", detail: "\(nsError.domain) \(nsError.code)")
            throw error
        }
    }

    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
