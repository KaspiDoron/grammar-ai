// swift-tools-version:6.0
import PackageDescription

// Grammar AI builds with the free Command Line Tools alone - no Xcode.app
// needed (Xcode works too: open Package.swift). The .app bundle is assembled
// by scripts/bundle-app.sh. There are no third-party dependencies.
//
// macOS 14 is the floor: it is the oldest macOS Apple still patches, and
// the APIs we rely on (SMAppService 13+, Observation 14+, Swift Testing 14+)
// are all available there.
let package = Package(
    name: "GrammarAI",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: models, prompt, validation, providers, pipeline,
        // settings. Foundation only, so everything is unit-testable.
        .target(
            name: "GrammarAICore",
            path: "Sources/GrammarAICore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // macOS integration without UI: Accessibility, pasteboard,
        // synthesized keys, global hotkey, launch at login.
        .target(
            name: "GrammarAISystem",
            dependencies: ["GrammarAICore"],
            path: "Sources/GrammarAISystem",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The menu-bar app: AppKit shell, SwiftUI settings and onboarding.
        .executableTarget(
            name: "GrammarAI",
            dependencies: ["GrammarAICore", "GrammarAISystem"],
            path: "Sources/GrammarAI",
            // Info.plist and the icon are copied by scripts/bundle-app.sh.
            exclude: ["Support"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GrammarAICoreTests",
            dependencies: ["GrammarAICore"],
            path: "Tests/GrammarAICoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GrammarAISystemTests",
            dependencies: ["GrammarAISystem", "GrammarAICore"],
            path: "Tests/GrammarAISystemTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
