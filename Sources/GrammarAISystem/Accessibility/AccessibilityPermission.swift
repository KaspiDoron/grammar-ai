import AppKit
import ApplicationServices

/// The one permission Grammar AI needs. Accessibility lets it read the text
/// you select and post the paste that replaces it.
public enum AccessibilityPermission {

    /// Silent check. Never shows a prompt.
    public static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks macOS to show its "would like to control this computer" dialog.
    /// macOS shows it at most once per app identity; the caller (onboarding)
    /// also only asks once, so the user is never nagged.
    @discardableResult
    public static func requestSystemPrompt() -> Bool {
        // The literal is the documented value of kAXTrustedCheckOptionPrompt.
        // The constant itself is a mutable global, which Swift 6 rejects.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings > Privacy & Security > Accessibility.
    @MainActor
    public static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }
}
