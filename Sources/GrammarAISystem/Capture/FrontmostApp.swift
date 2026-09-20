import AppKit

/// The app the user is working in at this instant.
public struct FrontmostApp: Equatable, Sendable {
    public let processID: pid_t
    public let bundleID: String?
    public let name: String?

    public init(processID: pid_t, bundleID: String?, name: String?) {
        self.processID = processID
        self.bundleID = bundleID
        self.name = name
    }

    @MainActor
    public static func current() -> FrontmostApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostApp(
            processID: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            name: app.localizedName
        )
    }

    /// Terminal emulators. A selection there is scrollback, not editable
    /// text, and a paste would type into the shell prompt - so Grammar AI
    /// never pastes into these and hands the correction over on the
    /// clipboard instead.
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "org.alacritty",
        "io.alacritty",
        "com.mitchellh.ghostty",
        "co.zeit.hyper",
        "org.tabby"
    ]

    /// Editors whose Cmd+C copies the whole current line when nothing is
    /// selected, without marking the clipboard the way VS Code does.
    public static let lineCopyEditorPrefixes = [
        "com.sublimetext.", "com.jetbrains.", "com.google.android.studio", "dev.zed.", "com.panic.Nova"
    ]

    public var copiesLineWhenNothingSelected: Bool {
        guard let bundleID else { return false }
        return Self.lineCopyEditorPrefixes.contains(where: bundleID.hasPrefix)
    }

    public var isTerminal: Bool {
        guard let bundleID else { return false }
        return Self.terminalBundleIDs.contains(bundleID)
    }
}

/// Seam for tests: lets the capturer and replacer be exercised without a
/// real frontmost application.
public protocol FrontmostAppProviding: Sendable {
    func current() async -> FrontmostApp?
}

public struct WorkspaceFrontmostAppProvider: FrontmostAppProviding {
    public init() {}
    public func current() async -> FrontmostApp? {
        await FrontmostApp.current()
    }
}
