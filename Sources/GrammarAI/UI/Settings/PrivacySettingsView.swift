import GrammarAICore
import SwiftUI

/// Plain-language privacy facts. Every line here is a statement about how
/// the code actually behaves - keep it in sync with PRIVACY.md.
struct PrivacySettingsView: View {

    var body: some View {
        Form {
            Section("What is sent, and when") {
                fact("text.cursor", "Only the text you select, and only at the moment you ask for a correction - with the shortcut, the menu, or right-click > Services.")
                fact("sparkles", "It goes to Claude: through the Claude Code app on this Mac, or straight to Anthropic's API if you use your own key. Anthropic's privacy terms for your account apply to it.")
                fact("nosign", "Nothing is sent in the background. There is no analytics and no telemetry.")
            }

            Section("What stays on this Mac") {
                fact("clock.arrow.circlepath", "No history. Your original text and the correction are held in memory for about a second and then discarded.")
                fact("keyboard", "No keystroke logging. Grammar AI never observes what you type; macOS only tells it when its own shortcut is pressed.")
                fact("rectangle.dashed", "No screen recording and no screenshots.")
                fact("lock.fill", "Password fields are never read.")
                fact("doc.text.magnifyingglass", "Logs contain event names and error codes only - never your text.")
            }

            Section("Your clipboard") {
                fact("doc.on.clipboard", "In apps that do not expose their text, Grammar AI briefly uses the clipboard to copy the selection and paste the correction. Your previous clipboard contents are restored right after, and the temporary text is marked so clipboard managers ignore it.")
            }

            Section("Your API key") {
                fact("key.fill", "If you add one, it is stored only in the macOS Keychain and is sent only to api.anthropic.com over HTTPS.")
            }

            Section {
                Link("Read the full privacy policy", destination: AppIdentity.repositoryURL.appendingPathComponent("blob/main/PRIVACY.md"))
            }
        }
        .formStyle(.grouped)
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }
}
