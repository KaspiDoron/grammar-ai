import GrammarAICore
import SwiftUI

struct CorrectionSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker(selection: $model.settings.mode) {
                    ForEach(CorrectionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: {
                    Text("Correction mode")
                    Text(model.settings.mode.summary)
                }

                if model.settings.mode == .custom {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Custom instruction")
                        TextEditor(text: $model.settings.customInstruction)
                            .font(.body)
                            .frame(height: 72)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel("Custom instruction")
                        Caption("Example: Correct my English but keep it casual and concise.")
                    }
                }
            }

            Section {
                Picker(selection: $model.settings.language) {
                    ForEach(CorrectionLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                } label: {
                    Text("Language")
                    Text("Automatic detects the language of each selection. Text is never translated.")
                }
            }

            Section {
                Toggle("Preserve tone", isOn: $model.settings.preserveTone)
                Toggle("Preserve slang", isOn: $model.settings.preserveSlang)
                Toggle("Preserve emojis", isOn: $model.settings.preserveEmojis)
            } header: {
                Text("Keep my voice")
            } footer: {
                Caption("Grammar AI fixes mistakes. It does not turn \"hey bro\" into \"Dear Sir\".")
            }
        }
        .formStyle(.grouped)
    }
}
