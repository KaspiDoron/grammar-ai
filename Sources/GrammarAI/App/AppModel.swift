import Foundation
import GrammarAICore
import GrammarAISystem
import Observation

/// What the app is doing right now, for the status item and the HUD.
enum Activity: Equatable {
    case idle
    case correcting
    /// Waiting for the user in the confirm panel.
    case confirming
}

/// A short message for the user: the outcome of the last run.
struct UserMessage: Equatable {
    enum Kind: Equatable { case success, info, failure }
    let kind: Kind
    let text: String
}

/// UI state shared by the menu, Settings and onboarding. Main-actor only.
@MainActor
@Observable
final class AppModel {

    /// Every preference. Assigning saves it and tells the coordinator.
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            onSettingsChanged?(oldValue, settings)
        }
    }

    var activity: Activity = .idle
    var lastMessage: UserMessage?

    /// Temporary pause from the menu. Not persisted: a relaunch resumes.
    var pausedUntil: Date?

    var isAccessibilityGranted = AccessibilityPermission.isGranted
    var providerStatus: ProviderStatus?
    var isCheckingProvider = false
    var hasAPIKey = false
    var hasOpenAIKey = false

    /// Why the global shortcut is not active, when it is not.
    var hotkeyProblem: String?
    var launchAtLoginState = LaunchAtLogin.state

    @ObservationIgnored var onSettingsChanged: ((_ old: AppSettings, _ new: AppSettings) -> Void)?
    @ObservationIgnored private let store: SettingsPersisting

    init(store: SettingsPersisting) {
        self.store = store
        self.settings = store.load()
    }

    var isPaused: Bool {
        guard let pausedUntil else { return false }
        return pausedUntil > Date()
    }

    /// The shortcut should be live only when corrections can actually run.
    var isActive: Bool {
        settings.isEnabled && !isPaused
    }

    var hotkeyDisplay: String {
        settings.hotkey?.localizedDisplayString ?? "None"
    }
}
