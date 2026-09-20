import Foundation
import Testing
@testable import GrammarAICore

@Suite("AppSettings and KeyCombo")
struct SettingsTests {

    @Test func defaultsMatchTheProductSpec() {
        let settings = AppSettings()
        #expect(settings.isEnabled)
        #expect(settings.hotkey == KeyCombo(keyCode: 5, modifiers: [.command, .shift]))
        #expect(settings.mode == .natural)
        #expect(settings.language == .automatic)
        #expect(settings.provider == .free)
        #expect(!settings.confirmBeforeReplacing)
        #expect(!settings.hasCompletedOnboarding)
        #expect(!settings.loadClaudeUserSettings)
    }

    @Test func roundTripsThroughJSON() throws {
        var settings = AppSettings()
        settings.mode = .custom
        settings.customInstruction = "keep it short 🙂"
        settings.language = .hebrew
        settings.hotkey = KeyCombo(keyCode: 40, modifiers: [.control, .option])
        settings.provider = .anthropicAPI
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test func aClearedShortcutSurvivesARoundTrip() throws {
        var settings = AppSettings()
        settings.hotkey = nil
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.hotkey == nil)
    }

    @Test func missingAndUnknownFieldsFallBackToDefaults() throws {
        let json = #"{"mode":"professional","someFutureField":123,"language":"klingon"}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.mode == .professional)
        #expect(decoded.language == .automatic)      // unknown value -> default
        #expect(decoded.hotkey == .defaultCorrection) // missing key -> default
        #expect(decoded.isEnabled)
    }

    @Test func storePersistsAndNeverHoldsSecrets() throws {
        let suite = "grammarai-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UserDefaultsSettingsStore(defaults: defaults)
        #expect(store.load() == AppSettings())

        var settings = AppSettings()
        settings.mode = .basic
        store.save(settings)
        #expect(store.load().mode == .basic)

        let stored = String(decoding: try #require(defaults.data(forKey: "settings.v1")), as: UTF8.self)
        #expect(!stored.lowercased().contains("apikey"))
        #expect(!stored.contains("sk-ant"))
    }

    @Test func derivedContextCarriesEveryCorrectionOption() {
        var settings = AppSettings()
        settings.mode = .professional
        settings.preserveEmojis = false
        settings.confirmBeforeReplacing = true
        #expect(settings.correctionContext.mode == .professional)
        #expect(!settings.correctionContext.preserveEmojis)
        #expect(settings.pipelineConfiguration.confirmBeforeReplacing)
    }

    @Test func automaticModelResolvesToTheFastestPerProvider() {
        #expect(ClaudeModel.automatic.resolved(for: .claudeCode) == .sonnet)
        #expect(ClaudeModel.automatic.resolved(for: .anthropicAPI) == .haiku)
        #expect(ClaudeModel.opus.resolved(for: .claudeCode) == .opus)
    }

    // MARK: KeyCombo

    @Test func displaysModifiersInMenuOrder() {
        let combo = KeyCombo(keyCode: 5, modifiers: [.command, .shift, .option, .control])
        #expect(combo.displayString() == "\u{2303}\u{2325}\u{21E7}\u{2318}G")
        #expect(KeyCombo.defaultCorrection.displayString() == "\u{21E7}\u{2318}G")
        #expect(KeyCombo.defaultCorrection.spokenDescription() == "Shift Command G")
    }

    @Test func aShortcutNeedsARealModifier() {
        #expect(!KeyCombo(keyCode: 5, modifiers: []).isValidGlobalShortcut)
        #expect(!KeyCombo(keyCode: 5, modifiers: [.shift]).isValidGlobalShortcut)
        #expect(KeyCombo(keyCode: 5, modifiers: [.option]).isValidGlobalShortcut)
    }

    @Test func specialKeysHaveLabels() {
        #expect(KeyCombo.fallbackKeyLabel(for: 49) == "Space")
        #expect(KeyCombo.fallbackKeyLabel(for: 96) == "F5")
        #expect(KeyCombo.fallbackKeyLabel(for: 999) == "Key 999")
    }
}
