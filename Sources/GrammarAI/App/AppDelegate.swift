import AppKit
import GrammarAICore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Developer tool: render the UI to PNG files and exit.
        if let directory = ScreenshotRenderer.requestedDirectory {
            Task {
                await ScreenshotRenderer.run(into: directory)
                NSApp.terminate(nil)
            }
            return
        }

        // One copy only: two would both answer the shortcut and paste twice.
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: AppIdentity.bundleIdentifier)
            .filter { $0 != .current }
        if !others.isEmpty, Bundle.main.bundleIdentifier == AppIdentity.bundleIdentifier {
            Log.info(.app, "another copy is running; quitting this one")
            NSApp.terminate(nil)
            return
        }

        MainMenu.install()
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }

    /// Opening the app again (Finder, Spotlight) while it is already running
    /// is how people look for a menu-bar app's window: show Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.showSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
