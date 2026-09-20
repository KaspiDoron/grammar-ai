import AppKit
import GrammarAICore
import SwiftUI

/// Developer tool: renders the app's windows to PNG files, off screen.
///
///     GrammarAI --screenshots docs/screenshots
///
/// Used for the README images and for checking the UI after a change. It
/// uses throwaway in-memory settings, registers no shortcut, and never
/// touches the user's real preferences, clipboard or screen.
@MainActor
enum ScreenshotRenderer {

    static var requestedDirectory: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--screenshots"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    static func run(into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let coordinator = AppCoordinator(store: InMemorySettingsStore())
        let model = coordinator.model
        model.providerStatus = .ready(detail: "2.1.278 (Claude Code)")
        model.isAccessibilityGranted = true

        let panes: [(String, AnyView)] = [
            ("settings-general", AnyView(GeneralSettingsView(model: model, coordinator: coordinator))),
            ("settings-correction", AnyView(CorrectionSettingsView(model: model))),
            ("settings-provider", AnyView(ProviderSettingsView(model: model, coordinator: coordinator))),
            ("settings-privacy", AnyView(PrivacySettingsView())),
            ("onboarding", AnyView(OnboardingView(model: model, coordinator: coordinator)))
        ]
        for (name, view) in panes {
            if name == "onboarding" {
                await render(view, named: name, into: directory, titled: true)
            } else {
                await render(SettingsPane { view }, named: name, into: directory, titled: true)
            }
        }

        let huds: [(String, HUDContent)] = [
            ("hud-progress", .progress("Correcting...")),
            ("hud-success", .message(UserMessage(kind: .success, text: "Corrected"))),
            ("hud-error", .message(UserMessage(kind: .failure, text: "Select some text first."))),
            ("hud-copied", .message(UserMessage(kind: .info, text: "You switched apps, so the correction was copied instead.")))
        ]
        for (name, content) in huds {
            await render(HUDView(content: content), named: name, into: directory, titled: false)
        }

        print("Wrote screenshots to \(directory.path)")
    }

    private static func render(_ view: some View, named name: String, into directory: URL, titled: Bool) async {
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = titled ? [.titled, .closable, .miniaturizable] : [.borderless]
        window.title = AppIdentity.displayName
        window.backgroundColor = titled ? .windowBackgroundColor : .clear
        window.isOpaque = titled
        window.isReleasedWhenClosed = false
        // Far off screen: laid out and drawn, never seen.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(400)) // let SwiftUI lay out

        guard let target = titled ? window.contentView?.superview : window.contentView,
              let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
        target.cacheDisplay(in: target.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: directory.appendingPathComponent("\(name).png"))
        }
        window.orderOut(nil)
    }
}

/// Settings that live and die with the process.
final class InMemorySettingsStore: SettingsPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var settings = AppSettings(hasCompletedOnboarding: true)

    func load() -> AppSettings { lock.withLock { settings } }
    func save(_ settings: AppSettings) { lock.withLock { self.settings = settings } }
}
