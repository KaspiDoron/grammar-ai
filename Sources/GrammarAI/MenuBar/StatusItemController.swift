import AppKit
import GrammarAICore
import GrammarAISystem
import Observation

/// The menu-bar icon and its menu. The menu is rebuilt each time it opens,
/// so it always reflects the current settings without any observers.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let model: AppModel
    private unowned let coordinator: AppCoordinator
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var pulseTimer: Timer?
    private var flashTask: Task<Void, Never>?

    init(model: AppModel, coordinator: AppCoordinator) {
        self.model = model
        self.coordinator = coordinator
        super.init()

        let menu = NSMenu()
        // Without this AppKit re-enables every item that has a target and
        // action, silently overriding the isEnabled values set below.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.setAccessibilityLabel(AppIdentity.displayName)
        refresh()
        observeActivity()
    }

    // MARK: - Icon

    func refresh() {
        guard let button = statusItem.button else { return }
        button.image = Self.symbol("text.badge.checkmark")
        // Dimmed when corrections are off or paused.
        button.appearsDisabled = !model.isActive
        button.toolTip = model.isActive
            ? "\(AppIdentity.displayName) - \(model.hotkeyDisplay)"
            : "\(AppIdentity.displayName) is \(model.settings.isEnabled ? "paused" : "off")"
    }

    /// Briefly shows the outcome in the icon itself, for users who turned the
    /// HUD off.
    func flash(_ kind: UserMessage.Kind) {
        guard kind == .failure, let button = statusItem.button else { return }
        flashTask?.cancel()
        button.image = Self.symbol("exclamationmark.triangle")
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// A gentle pulse while a correction is in flight. The timer exists only
    /// for that second or so; idle, the app does no periodic work at all.
    private func observeActivity() {
        withObservationTracking {
            _ = model.activity
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updatePulse()
                self?.observeActivity()
            }
        }
    }

    private func updatePulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        guard let button = statusItem.button else { return }
        guard model.activity == .correcting else {
            button.alphaValue = 1
            return
        }
        var dim = false
        let timer = Timer(timeInterval: 0.45, repeats: true) { [weak button] _ in
            MainActor.assumeIsolated {
                dim.toggle()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.4
                    button?.animator().alphaValue = dim ? 0.35 : 1
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: AppIdentity.displayName)
        image?.isTemplate = true
        return image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = model.settings

        let title = NSMenuItem(title: AppIdentity.displayName, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        if let message = model.lastMessage, message.kind != .success {
            let last = NSMenuItem(title: message.text, action: nil, keyEquivalent: "")
            last.isEnabled = false
            menu.addItem(last)
        }
        menu.addItem(.separator())

        if !AccessibilityPermission.isGranted {
            menu.addItem(item("Grant Accessibility Access...", #selector(grantAccess)))
            menu.addItem(.separator())
        }

        let enabled = item("Enabled", #selector(toggleEnabled))
        enabled.state = settings.isEnabled ? .on : .off
        menu.addItem(enabled)

        let correct = item("Correct Selected Text", #selector(correctNow))
        if let hotkey = settings.hotkey, model.isActive {
            applyKeyEquivalent(of: hotkey, to: correct)
        }
        correct.isEnabled = settings.isEnabled && model.activity == .idle
        menu.addItem(correct)

        if model.activity != .idle {
            menu.addItem(item("Cancel Correction", #selector(cancelNow)))
        }
        menu.addItem(.separator())

        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        modeMenu.autoenablesItems = false
        for mode in CorrectionMode.allCases {
            let entry = item(mode.displayName, #selector(selectMode(_:)))
            entry.representedObject = mode.rawValue
            entry.state = settings.mode == mode ? .on : .off
            entry.toolTip = mode.summary
            modeMenu.addItem(entry)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)
        menu.addItem(.separator())

        let settingsItem = item("Settings...", #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)

        let pause = item(model.isPaused ? "Resume" : "Pause for 1 Hour", #selector(togglePause))
        pause.isEnabled = settings.isEnabled
        menu.addItem(pause)
        menu.addItem(.separator())

        let quit = item("Quit \(AppIdentity.displayName)", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Shows the global shortcut next to the item, the way menus draw them.
    private func applyKeyEquivalent(of combo: KeyCombo, to item: NSMenuItem) {
        let label = combo.keyLabel
        guard label.count == 1 else {
            item.title += "   \(combo.localizedDisplayString)"
            return
        }
        item.keyEquivalent = label.lowercased()
        var mask: NSEvent.ModifierFlags = []
        if combo.modifiers.contains(.command) { mask.insert(.command) }
        if combo.modifiers.contains(.shift) { mask.insert(.shift) }
        if combo.modifiers.contains(.option) { mask.insert(.option) }
        if combo.modifiers.contains(.control) { mask.insert(.control) }
        item.keyEquivalentModifierMask = mask
    }

    // MARK: - Actions

    @objc private func toggleEnabled() { model.settings.isEnabled.toggle() }
    @objc private func correctNow() { coordinator.correctSelection(trigger: .menu) }
    @objc private func cancelNow() { coordinator.cancelCorrection() }
    @objc private func openSettings() { coordinator.showSettings() }
    @objc private func togglePause() { coordinator.togglePause() }
    @objc private func grantAccess() { coordinator.requestAccessibility() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = CorrectionMode(rawValue: raw) else { return }
        model.settings.mode = mode
    }
}
