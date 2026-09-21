import Foundation

/// The one place the product's name and identifiers live, so a rename is a
/// change here plus `Support/Info.plist`.
public enum AppIdentity {
    public static let displayName = "Typfix"
    public static let bundleIdentifier = "com.kaspidoron.grammarai"
    // Bundle ID stays com.kaspidoron.grammarai: macOS ties the Accessibility
    // grant and the Keychain item to it, so renaming the brand must not change it.
    /// Folder name under Application Support.
    public static let supportDirectoryName = "GrammarAI"
    public static let repositoryURL = URL(string: "https://github.com/KaspiDoron/grammar-ai")!
}
