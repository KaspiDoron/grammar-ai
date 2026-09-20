import AppKit
import GrammarAICore
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {

    private let window: NSWindow
    private unowned let coordinator: AppCoordinator

    init(model: AppModel, coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let view = OnboardingView(model: model, coordinator: coordinator)
        window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to \(AppIdentity.displayName)"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init()
        window.delegate = self
        window.center()
    }

    func present() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
    }

    /// Closing the window early counts as "done": onboarding must not come
    /// back on every launch. Everything in it is reachable from Settings and
    /// the menu bar icon.
    func windowWillClose(_ notification: Notification) {
        // Deferred: finishing releases this controller, which must not
        // happen while AppKit is still inside its delegate callback.
        let coordinator = self.coordinator
        Task { @MainActor in coordinator.finishOnboarding() }
    }
}

/// First launch, in six short steps. Nothing here is mandatory: the window
/// can be closed at any point and everything is reachable from Settings.
struct OnboardingView: View {
    @Bindable var model: AppModel
    let coordinator: AppCoordinator

    @State private var step = Step.welcome
    @State private var askedForAccess = false
    @State private var test = TestState.idle

    private enum Step: Int, CaseIterable { case welcome, shortcut, access, claude, test, done }

    private enum TestState: Equatable {
        case idle, running
        case passed(String)
        case failed(String)
    }

    private static let sample = "i dont think this is working properly"

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 44)
                .padding(.top, 40)

            Divider()
            HStack {
                if step != .welcome && step != .done {
                    Button("Back") { move(-1) }
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(Step.allCases, id: \.self) { item in
                        Circle()
                            .fill(item == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityHidden(true)
                Spacer()
                Button(step == .done ? "Finish" : "Continue") {
                    step == .done ? coordinator.finishOnboarding() : move(1)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 430)
        .onChange(of: step) { old, new in
            if old == .access { coordinator.endPermissionPolling(for: .onboarding) }
            if new == .access { coordinator.beginPermissionPolling(for: .onboarding) }
            if new == .claude { coordinator.refreshProviderStatus() }
        }
        .onDisappear {
            if step == .access { coordinator.endPermissionPolling(for: .onboarding) }
        }
    }

    private func move(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { step = next }
    }

    // MARK: - Steps

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            page("text.badge.checkmark", "Fix your writing anywhere on your Mac.",
                 "Select text in any app, press a shortcut, and Claude corrects it in place - keeping your tone, your slang and your meaning.")
        case .shortcut:
            page("keyboard", "Select text and press \(model.hotkeyDisplay).",
                 "That is the whole workflow. You can also right-click a selection and choose Services > Correct with Grammar AI.") {
                LabeledContent("Shortcut") {
                    ShortcutRecorder(combo: $model.settings.hotkey) { coordinator.setHotkeySuspended($0) }
                }
                .frame(maxWidth: 300)
            }
        case .access:
            page("hand.raised", "Allow Accessibility access",
                 "Grammar AI needs Accessibility access so it can read the text you select and replace it with the corrected version. It never reads anything else.") {
                if model.isAccessibilityGranted {
                    Label("Access granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.headline)
                } else {
                    Button("Open System Settings") {
                        askedForAccess = true
                        coordinator.requestAccessibility()
                    }
                    .controlSize(.large)
                    if askedForAccess {
                        Caption("In Privacy & Security > Accessibility, switch on Grammar AI. This page updates by itself.")
                            .multilineTextAlignment(.center)
                    }
                }
            }
        case .claude:
            page("sparkles", "Free and private, out of the box",
                 "Grammar AI corrects your text with a free model running on this Mac (via Ollama) and falls back to the Claude Code app if it isn't running. No API key, no subscription. Change it any time in Settings > AI Provider.") {
                providerStatus
            }
        case .test:
            page("checkmark.seal", "Try it", "This sends one sample sentence to the AI.") {
                Text(Self.sample)
                    .font(.system(.body, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                Button(test == .running ? "Correcting..." : "Test Correction", action: runTest)
                    .disabled(test == .running)
                switch test {
                case .idle, .running:
                    EmptyView()
                case .passed(let text):
                    Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        case .done:
            page("party.popper", "You're ready.",
                 "Grammar AI lives in your menu bar. Select some text anywhere and press \(model.hotkeyDisplay).") {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLoginState == .enabled || model.launchAtLoginState == .requiresApproval },
                    set: { coordinator.setLaunchAtLogin($0) }
                ))
                .disabled(model.launchAtLoginState == .unavailable)
                .toggleStyle(.checkbox)
            }
        }
    }

    @ViewBuilder private var providerStatus: some View {
        if let status = model.providerStatus {
            if status.isReady {
                Label("Connected - \(status.detail)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.headline)
            } else {
                Label(status.detail, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Caption("Install Claude Code from claude.com/claude-code, run `claude` once in Terminal to sign in, then check again.")
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Check Again") { coordinator.refreshProviderStatus() }
                    Button("Use an API Key Instead") { coordinator.showSettings() }
                }
            }
        } else {
            ProgressView()
        }
    }

    private func page(_ symbol: String, _ title: String, _ message: String) -> some View {
        page(symbol, title, message) { EmptyView() }
    }

    private func page<Extra: View>(
        _ symbol: String, _ title: String, _ message: String, @ViewBuilder extra: () -> Extra
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(height: 56)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            extra()
                .padding(.top, 6)
            Spacer(minLength: 0)
        }
    }

    private func runTest() {
        test = .running
        Task {
            switch await coordinator.correct(text: Self.sample) {
            case .success(let result): test = .passed(result.correctedText)
            case .failure(let error): test = .failed(error.userMessage)
            }
        }
    }
}
