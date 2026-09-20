import GrammarAICore
import SwiftUI

struct ProviderSettingsView: View {
    @Bindable var model: AppModel
    let coordinator: AppCoordinator

    @State private var apiKeyDraft = ""
    @State private var keyError: String?
    @State private var test = TestState.idle

    private enum TestState: Equatable {
        case idle
        case running
        case passed(String, seconds: Double)
        case failed(String)
    }

    private static let sample = "i dont think this is working properly"

    var body: some View {
        Form {
            Section {
                Picker(selection: $model.settings.provider) {
                    ForEach(ProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                } label: {
                    Text("Provider")
                    Text(model.settings.provider.summary)
                }

                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        statusView
                        Button {
                            coordinator.refreshProviderStatus()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Check again")
                        .accessibilityLabel("Check status again")
                    }
                }
            }

            Section {
                Picker(selection: $model.settings.model) {
                    ForEach(ClaudeModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                } label: {
                    Text("Model")
                    Text("Automatic picks the fastest model for this provider. A grammar fix does not need the biggest one.")
                }
            }

            switch model.settings.provider {
            case .claudeCode: claudeCodeSection
            case .anthropicAPI: apiKeySection
            }

            Section {
                HStack {
                    Button(test == .running ? "Testing..." : "Test Correction") { runTest() }
                        .disabled(test == .running)
                    Spacer()
                }
                switch test {
                case .idle:
                    Caption("Sends the sample sentence \"\(Self.sample)\" to Claude.")
                case .running:
                    ProgressView().controlSize(.small)
                case .passed(let text, let seconds):
                    Label("\(text)  (\(String(format: "%.1f", seconds)) s)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { coordinator.refreshProviderStatus() }
    }

    // MARK: - Sections

    @ViewBuilder private var statusView: some View {
        if model.isCheckingProvider && model.providerStatus == nil {
            ProgressView().controlSize(.small)
        } else if let status = model.providerStatus {
            if status.isReady {
                Label("Connected - \(status.detail)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label(status.detail, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } else {
            Text("Unknown").foregroundStyle(.secondary)
        }
    }

    private var claudeCodeSection: some View {
        Section("Claude Code") {
            TextField(text: $model.settings.claudeExecutablePath, prompt: Text("Found automatically")) {
                Text("Path to claude")
                Text("Leave empty unless Claude Code is installed somewhere unusual. Sign in once by running claude in Terminal.")
            }
            Toggle(isOn: $model.settings.loadClaudeUserSettings) {
                Text("Load my Claude Code settings")
                Text("Off by default, so none of your hooks or plugins run for a correction. Turn on only if Claude Code signs in through its settings (apiKeyHelper, Bedrock, Vertex).")
            }
        }
    }

    private var apiKeySection: some View {
        Section("Anthropic API key") {
            if model.hasAPIKey {
                HStack {
                    Label("Saved in your Keychain", systemImage: "key.fill")
                    Spacer()
                    Button("Remove", role: .destructive) { coordinator.removeAPIKey() }
                }
            } else {
                HStack {
                    // A secure field: the key is never shown in clear text,
                    // and it is never written anywhere but the Keychain.
                    SecureField("API key", text: $apiKeyDraft, prompt: Text("sk-ant-..."))
                        .textContentType(.password)
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey)
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let keyError {
                    Label(keyError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            Caption("Create a key at console.anthropic.com. It is stored only in the macOS Keychain on this Mac.")
        }
    }

    // MARK: - Actions

    private func saveKey() {
        if coordinator.saveAPIKey(apiKeyDraft) {
            keyError = nil
        } else {
            keyError = "Couldn't save the key to the Keychain."
        }
        apiKeyDraft = ""
    }

    private func runTest() {
        test = .running
        let started = Date()
        Task {
            switch await coordinator.correct(text: Self.sample) {
            case .success(let result):
                test = .passed(result.correctedText, seconds: Date().timeIntervalSince(started))
            case .failure(let error):
                test = .failed(error.userMessage)
            }
            coordinator.refreshProviderStatus()
        }
    }
}
