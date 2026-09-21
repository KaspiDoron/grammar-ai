import GrammarAICore
import SwiftUI

struct ProviderSettingsView: View {
    @Bindable var model: AppModel
    let coordinator: AppCoordinator

    @State private var apiKeyDraft = ""
    @State private var keyError: String?
    @State private var openAIKeyDraft = ""
    @State private var openAIKeyError: String?
    @State private var test = TestState.idle
    @State private var ollamaModels: [String] = []

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

            switch model.settings.provider {
            case .free: freeSection
            case .ollama: ollamaSection
            case .claudeCode: claudeCodeSection
            case .anthropicAPI: apiKeySection
            case .openAI: openAISection
            }

            if model.settings.provider == .claudeCode || model.settings.provider == .anthropicAPI {
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
            }

            Section {
                HStack {
                    Button(test == .running ? "Testing..." : "Test Correction") { runTest() }
                        .disabled(test == .running)
                    Spacer()
                }
                switch test {
                case .idle:
                    Caption("Sends the sample sentence \"\(Self.sample)\" to the AI.")
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
        .onAppear {
            coordinator.refreshProviderStatus()
            Task { ollamaModels = await coordinator.installedOllamaModels() }
        }
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

    @ViewBuilder private var freeSection: some View {
        Section("How the free option works") {
            step(1, "A model running locally in Ollama corrects your text. It is free, and your text never leaves this Mac.")
            step(2, "If Ollama isn't running, the Claude Code app on this Mac takes over automatically, so a correction still happens.")
            Caption("You don't have to choose - whichever is available is used. Set up either or both below.")
        }
        ollamaSection
        Section("Backup: Claude Code") {
            LabeledContent("Status") { providerLine(coordinator.claudeCodeReady) }
            Caption("Install Claude Code and run `claude` once in Terminal to sign in. Optional - the local model alone is enough.")
        }
    }

    @ViewBuilder private var ollamaSection: some View {
        Section("Ollama (local model)") {
            if ollamaModels.isEmpty {
                Label("Ollama not detected", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Caption("Install it from ollama.com, then run `ollama pull \(OllamaProvider.defaultModel)`. It runs entirely on your Mac.")
                Link("Get Ollama", destination: URL(string: "https://ollama.com")!)
            } else {
                Picker(selection: $model.settings.ollamaModel) {
                    ForEach(ollamaModels, id: \.self) { name in
                        Text(name).tag(name)
                    }
                    if !ollamaModels.contains(model.settings.ollamaModel) {
                        Text("\(model.settings.ollamaModel) (not installed)").tag(model.settings.ollamaModel)
                    }
                } label: {
                    Text("Model")
                    Text("A small model such as qwen3:1.7b is fast and accurate enough for grammar. Larger models are slower.")
                }
                Button("Refresh model list") {
                    Task { ollamaModels = await coordinator.installedOllamaModels() }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color.accentColor, in: Circle())
        }
    }

    @ViewBuilder private func providerLine(_ ready: Bool?) -> some View {
        switch ready {
        case .some(true): Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .some(false): Label("Not set up", systemImage: "circle.dashed").foregroundStyle(.secondary)
        case .none: ProgressView().controlSize(.small)
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

    @ViewBuilder private var openAISection: some View {
        Section("Cloud API key") {
            if model.hasOpenAIKey {
                HStack {
                    Label("Saved in your Keychain", systemImage: "key.fill")
                    Spacer()
                    Button("Remove", role: .destructive) { coordinator.removeAPIKey(kind: .openAI) }
                }
            } else {
                HStack {
                    SecureField("API key", text: $openAIKeyDraft, prompt: Text("sk-..."))
                        .textContentType(.password)
                        .onSubmit(saveOpenAIKey)
                    Button("Save", action: saveOpenAIKey)
                        .disabled(openAIKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let openAIKeyError {
                    Label(openAIKeyError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            Caption("Stored only in the macOS Keychain on this Mac. This is a paid, cloud provider - your text is sent to it.")
        }
        Section("Model and endpoint") {
            TextField(text: $model.settings.openAIModel, prompt: Text(OpenAIProvider.defaultModel)) {
                Text("Model")
                Text("For OpenAI: gpt-4o-mini (fast) or gpt-4o. For others, use their model id.")
            }
            TextField(text: $model.settings.openAIBaseURL, prompt: Text("https://api.openai.com/v1")) {
                Text("API base URL")
                Text("Leave empty for OpenAI. Point it at Groq, OpenRouter, DeepSeek or any OpenAI-compatible endpoint to use those instead.")
            }
            ForEach(Self.presets, id: \.name) { preset in
                Button("Use \(preset.name)") {
                    model.settings.openAIBaseURL = preset.url
                    model.settings.openAIModel = preset.model
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
        }
    }

    private static let presets: [(name: String, url: String, model: String)] = [
        ("OpenAI", "https://api.openai.com/v1", "gpt-4o-mini"),
        ("Groq (fast, free tier)", "https://api.groq.com/openai/v1", "llama-3.3-70b-versatile"),
        ("OpenRouter", "https://openrouter.ai/api/v1", "google/gemini-2.0-flash-001"),
        ("DeepSeek", "https://api.deepseek.com/v1", "deepseek-chat")
    ]

    // MARK: - Actions

    private func saveOpenAIKey() {
        if coordinator.saveAPIKey(openAIKeyDraft, kind: .openAI) {
            openAIKeyError = nil
        } else {
            openAIKeyError = "Couldn't save the key to the Keychain."
        }
        openAIKeyDraft = ""
    }

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
