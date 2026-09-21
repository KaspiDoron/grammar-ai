import GrammarAICore
import GrammarAISystem
import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var model: AppModel
    let coordinator: AppCoordinator

    var body: some View {
        Form {
            Section {
                Toggle("Enable grammar correction", isOn: $model.settings.isEnabled)
                Toggle(isOn: launchAtLogin) {
                    Text("Launch at login")
                    if model.launchAtLoginState == .unavailable {
                        Text("Available when running the installed app.")
                    }
                }
                .disabled(model.launchAtLoginState == .unavailable)
                if model.launchAtLoginState == .requiresApproval {
                    HStack {
                        Caption("macOS needs your approval in Login Items.")
                        Spacer()
                        Button("Open Login Items") { LaunchAtLogin.openLoginItemsSettings() }
                    }
                }
            }

            Section {
                LabeledContent("Global shortcut") {
                    ShortcutRecorder(combo: $model.settings.hotkey) { recording in
                        coordinator.setHotkeySuspended(recording)
                    }
                }
                if let problem = model.hotkeyProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if let conflict = conflict {
                    Label(conflict.message, systemImage: conflict.severity == .system
                          ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(conflict.severity == .system ? .orange : .secondary)
                        .font(.callout)
                } else if model.settings.hotkey == nil {
                    Caption("No shortcut set. Use the menu bar icon or right-click > Services instead.")
                }
            } footer: {
                Caption("Select text in any app, then press the shortcut.")
            }

            Section {
                Toggle(isOn: $model.settings.showNotifications) {
                    Text("Show notifications")
                    Text("A small status pill while correcting and when done. Problems are always shown.")
                }
                Toggle(isOn: $model.settings.confirmBeforeReplacing) {
                    Text("Confirm before replacing")
                    Text("Review the correction first: Return replaces, Esc cancels.")
                }
            }

            Section {
                Toggle(isOn: $model.settings.automaticSuggestions) {
                    Text("Suggest as I type")
                    Text("Watches the field you are typing in and, when you finish a sentence, shows a small fix near the cursor. Press the shortcut to accept, or keep typing to dismiss. It never changes your text on its own.")
                }
                Caption("Uses the free local model (Ollama) only - your text stays on this Mac - and needs Accessibility access. Works best in native text fields (Notes, Mail, TextEdit, Safari fields).")
            } header: {
                Text("Automatic")
            }

            Section("Accessibility access") {
                LabeledContent {
                    if model.isAccessibilityGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open System Settings") { coordinator.requestAccessibility() }
                    }
                } label: {
                    Text(model.isAccessibilityGranted ? "Allowed" : "Not allowed yet")
                    Text("Grammar AI needs Accessibility access so it can read the text you select and replace it with the corrected version.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { coordinator.beginPermissionPolling(for: .settings) }
        .onDisappear { coordinator.endPermissionPolling(for: .settings) }
    }

    private var conflict: HotkeyConflict? {
        model.settings.hotkey.flatMap(HotkeyConflicts.conflict(for:))
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { model.launchAtLoginState == .enabled || model.launchAtLoginState == .requiresApproval },
            set: { coordinator.setLaunchAtLogin($0) }
        )
    }
}
