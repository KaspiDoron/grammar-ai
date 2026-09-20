import Foundation

/// The one place the product's name and identifiers live, so a rename is a
/// change here plus `Support/Info.plist`.
public enum AppIdentity {
    public static let displayName = "Grammar AI"
    public static let bundleIdentifier = "com.kaspidoron.grammarai"
    /// Folder name under Application Support.
    public static let supportDirectoryName = "GrammarAI"
    public static let repositoryURL = URL(string: "https://github.com/KaspiDoron/grammar-ai")!
}
