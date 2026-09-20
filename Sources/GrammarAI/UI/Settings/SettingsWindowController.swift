import AppKit
import GrammarAICore
import SwiftUI

/// The Settings window: a standard toolbar-tab preferences window (AppKit)
/// whose panes are SwiftUI forms.
///
/// The SwiftUI `Settings` scene is not used because opening it from code is
/// unreliable in an accessory (menu-bar) app.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let window: NSWindow
    private unowned let coordinator: AppCoordinator

    init(model: AppModel, coordinator: AppCoordinator) {
        self.coordinator = coordinator

        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []

        func pane<Content: View>(_ title: String, _ symbol: String, _ view: Content) {
            let controller = NSHostingController(rootView: SettingsPane { view })
            controller.sizingOptions = [.preferredContentSize]
            controller.title = title
            let item = NSTabViewItem(viewController: controller)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        pane("General", "gearshape", GeneralSettingsView(model: model, coordinator: coordinator))
        pane("Correction", "text.badge.checkmark", CorrectionSettingsView(model: model))
        pane("AI Provider", "sparkles", ProviderSettingsView(model: model, coordinator: coordinator))
        pane("Privacy", "hand.raised", PrivacySettingsView())

        window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "\(AppIdentity.displayName) Settings"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.toolbarStyle = .preference
        super.init()
        window.delegate = self
        window.center()
    }

    func present() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        coordinator.windowClosed(.settings)
    }
}

/// Sizes a settings form to its content. A grouped `Form` is a scroll view
/// with no natural height, so without this the window would collapse to its
/// toolbar. The height is capped for small screens; taller panes scroll.
struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 500)
    }
}

/// A caption under a control, in the standard secondary style.
struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
