import AppKit
import GrammarAICore
import GrammarAISystem

/// Wires the pieces together: hotkey -> pipeline -> HUD, plus the windows.
/// Everything here runs on the main actor; the pipeline does its work off it.
@MainActor
final class AppCoordinator {

    let model: AppModel

    private let keychain = KeychainManager()
    private let store: SettingsPersisting
    private let hotkeys = HotkeyManager()
    private let hud = HUDController()
    private let confirmPanel = ConfirmPanelController()
    private var pipeline: CorrectionPipeline!
    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController?
    private var onboardingWindow: OnboardingWindowController?
    private var servicesProvider: ServicesProvider?
    private var permissionTimer: Timer?
    private var pauseTimer: Timer?
    private var permissionPollers = Set<PermissionScreen>()
    private var providerCheckGeneration = 0

    /// The screens that show live Accessibility status.
    enum PermissionScreen { case settings, onboarding }

    init(store: SettingsPersisting = UserDefaultsSettingsStore()) {
        self.store = store
        self.model = AppModel(store: store)
    }

    // MARK: - Lifecycle

    func start() {
        let store = self.store
        let factory = ProviderFactory(keyProvider: KeychainAPIKeyProvider(keychain: keychain))

        pipeline = CorrectionPipeline(
            capturer: SelectionCapturer(),
            replacer: TextReplacer(),
            confirmer: confirmPanel,
            // Settings are saved on every change, so the store is current.
            makeProvider: { factory.makeProvider(for: store.load()) },
            configuration: { store.load().pipelineConfiguration },
            observer: { [weak self] event in
                await self?.handle(event)
            }
        )

        model.hasAPIKey = keychain.read(account: KeychainAPIKeyProvider.account) != nil
        model.onSettingsChanged = { [weak self] old, new in
            self?.settingsChanged(from: old, to: new)
        }

        hotkeys.onTrigger = { [weak self] in
            self?.correctSelection(trigger: .hotkey)
        }
        statusItem = StatusItemController(model: model, coordinator: self)

        let provider = ServicesProvider(coordinator: self)
        servicesProvider = provider
        provider.register()

        applyHotkey()
        refreshProviderStatus()

        if !model.settings.hasCompletedOnboarding {
            showOnboarding()
        }
        Log.info(.app, "started")
    }

    // MARK: - Correcting

    func correctSelection(trigger: CorrectionTrigger) {
        guard model.isActive || trigger == .menu else { return }
        Log.info(.pipeline, "triggered", detail: trigger.rawValue)
        Task {
            if trigger == .menu {
                // The menu is still closing; let the target app's window
                // become key again so its selection is readable.
                try? await Task.sleep(for: .milliseconds(250))
            }
            let outcome = await pipeline.run()
            if outcome == .busy {
                Log.info(.pipeline, "ignored: already correcting")
            }
        }
    }

    func cancelCorrection() {
        Task { await pipeline.cancel() }
    }

    /// Corrects text without touching any document: the onboarding test and
    /// the Services menu.
    func correct(text: String) async -> Result<CorrectionResult, CorrectionError> {
        do {
            return .success(try await pipeline.correct(text: text))
        } catch let error as CorrectionError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.providerUnavailable("unexpected: \(type(of: error))"))
        }
    }

    private func handle(_ event: PipelineEvent) {
        switch event {
        case .correcting:
            model.activity = .correcting
            if model.settings.showNotifications {
                hud.showProgress("Correcting...")
            }
        case .confirming:
            // The model has answered; the spinner would be a lie now.
            model.activity = .confirming
            hud.hide()
        case .finished(let outcome):
            model.activity = .idle
            present(outcome)
        }
    }

    private func present(_ outcome: PipelineOutcome) {
        let message: UserMessage?
        switch outcome {
        case .replaced:
            message = UserMessage(kind: .success, text: "Corrected")
        case .unchanged:
            message = UserMessage(kind: .success, text: "Already looks good")
        case .copiedToClipboard(let reason):
            message = UserMessage(kind: .info, text: reason)
        case .failed(.cancelled):
            message = nil
        case .failed(let error):
            Log.error(.pipeline, "failed", detail: error.logDetail)
            message = UserMessage(kind: .failure, text: error.userMessage)
            if error == .accessibilityDenied {
                model.isAccessibilityGranted = false
            }
        case .busy, .disabled:
            message = nil
        }

        model.lastMessage = message
        guard let message else {
            hud.hide()
            return
        }
        // Failures and "copied instead" always show: the user is waiting for
        // text to change and must learn why it did not. "Show notifications"
        // only silences progress and success.
        if model.settings.showNotifications || message.kind != .success {
            hud.show(message)
        } else {
            hud.hide()
        }
        statusItem.flash(message.kind)
    }

    // MARK: - Settings side effects

    private func settingsChanged(from old: AppSettings, to new: AppSettings) {
        if !old.isEnabled, new.isEnabled, model.isPaused {
            // Switching it on by hand means "work now", not "work in an hour".
            pauseTimer?.invalidate()
            pauseTimer = nil
            model.pausedUntil = nil
        }
        if old.hotkey != new.hotkey || old.isEnabled != new.isEnabled {
            applyHotkey()
        }
        if old.provider != new.provider || old.model != new.model
            || old.claudeExecutablePath != new.claudeExecutablePath {
            refreshProviderStatus()
        }
        statusItem.refresh()
    }

    /// The shortcut is registered only while corrections can run, so when
    /// Grammar AI is off or paused the keys go to the frontmost app again.
    func applyHotkey() {
        hotkeys.unregister()
        model.hotkeyProblem = nil
        guard model.isActive, let combo = model.settings.hotkey else { return }
        do {
            try hotkeys.register(combo)
        } catch HotkeyError.invalidCombination {
            model.hotkeyProblem = "A shortcut needs Command, Control or Option."
        } catch {
            model.hotkeyProblem = "macOS refused this shortcut. Try a different one."
        }
    }

    /// While the recorder listens, the live shortcut must not fire.
    func setHotkeySuspended(_ suspended: Bool) {
        if suspended { hotkeys.unregister() } else { applyHotkey() }
    }

    // MARK: - Pause

    func togglePause() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        if model.isPaused {
            model.pausedUntil = nil
        } else {
            let until = Date().addingTimeInterval(3600)
            model.pausedUntil = until
            let timer = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.model.pausedUntil = nil
                    self?.applyHotkey()
                    self?.statusItem.refresh()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            pauseTimer = timer
        }
        applyHotkey()
        statusItem.refresh()
    }

    // MARK: - Provider

    func refreshProviderStatus() {
        let settings = model.settings
        let factory = ProviderFactory(keyProvider: KeychainAPIKeyProvider(keychain: keychain))
        model.isCheckingProvider = true
        // Checks can finish out of order (typing a path starts one per
        // keystroke); only the newest may report.
        providerCheckGeneration += 1
        let generation = providerCheckGeneration
        Task {
            let status = await factory.makeProvider(for: settings).checkAvailability()
            guard generation == providerCheckGeneration else { return }
            model.providerStatus = status
            model.isCheckingProvider = false
        }
    }

    func saveAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try keychain.save(trimmed, account: KeychainAPIKeyProvider.account)
            model.hasAPIKey = true
            refreshProviderStatus()
            return true
        } catch {
            Log.error(.settings, "keychain save failed")
            return false
        }
    }

    func removeAPIKey() {
        try? keychain.delete(account: KeychainAPIKeyProvider.account)
        model.hasAPIKey = false
        refreshProviderStatus()
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        try? LaunchAtLogin.setEnabled(enabled)
        model.launchAtLoginState = LaunchAtLogin.state
    }

    // MARK: - Accessibility permission

    /// Checks once a second, but ONLY while a screen showing the permission
    /// is open. Tracked per screen (not counted), because SwiftUI does not
    /// promise balanced appear/disappear calls for hosted panes; closing a
    /// window ends its polling for certain.
    func beginPermissionPolling(for screen: PermissionScreen) {
        permissionPollers.insert(screen)
        model.isAccessibilityGranted = AccessibilityPermission.isGranted
        guard permissionTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.isAccessibilityGranted = AccessibilityPermission.isGranted
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    func endPermissionPolling(for screen: PermissionScreen) {
        permissionPollers.remove(screen)
        guard permissionPollers.isEmpty else { return }
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    func requestAccessibility() {
        // The system dialog appears at most once per app identity; after
        // that this only opens the right pane, which is what the user needs.
        AccessibilityPermission.requestSystemPrompt()
        AccessibilityPermission.openSystemSettings()
    }

    // MARK: - Windows

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(model: model, coordinator: self)
        }
        model.launchAtLoginState = LaunchAtLogin.state
        model.isAccessibilityGranted = AccessibilityPermission.isGranted
        settingsWindow?.present()
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindowController(model: model, coordinator: self)
        }
        onboardingWindow?.present()
    }

    func finishOnboarding() {
        model.settings.hasCompletedOnboarding = true
        onboardingWindow?.close()
        onboardingWindow = nil
        windowClosed(.onboarding)
    }

    /// A closed window can neither poll nor keep the shortcut suspended for
    /// a recording that will never finish.
    func windowClosed(_ screen: PermissionScreen) {
        endPermissionPolling(for: screen)
        applyHotkey()
    }

    func showServiceMessage(_ message: UserMessage) {
        model.lastMessage = message
        hud.show(message)
    }
}
