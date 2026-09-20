import AppKit

/// The clipboard operations capture and replacement need, behind a protocol
/// so tests run against a private pasteboard (or a fake) and never touch the
/// user's real clipboard.
public protocol ClipboardAccessing: Sendable {
    func changeCount() async -> Int
    func snapshot() async -> PasteboardSnapshot
    func restore(_ snapshot: PasteboardSnapshot) async
    func plainText() async -> String?
    /// True when the clipboard content is an editor's "copy the whole line
    /// because nothing was selected" - which must count as no selection.
    func isEmptySelectionCopy() async -> Bool
    /// Writes temporary text (tagged for clipboard managers to ignore) and
    /// returns the resulting change count.
    func writeTransient(_ text: String) async -> Int
    /// Writes text the user is meant to keep.
    func write(_ text: String) async
}

public struct SystemClipboard: ClipboardAccessing {

    private let name: NSPasteboard.Name

    /// Defaults to the general pasteboard; tests pass a unique name.
    public init(name: NSPasteboard.Name = .general) {
        self.name = name
    }

    @MainActor private var pasteboard: NSPasteboard { NSPasteboard(name: name) }

    public func changeCount() async -> Int {
        await MainActor.run { pasteboard.changeCount }
    }

    public func snapshot() async -> PasteboardSnapshot {
        await MainActor.run { PasteboardSnapshot.capture(from: pasteboard) }
    }

    public func restore(_ snapshot: PasteboardSnapshot) async {
        await MainActor.run { snapshot.restore(to: pasteboard) }
    }

    public func plainText() async -> String? {
        await MainActor.run { pasteboard.string(forType: .string) }
    }

    public func isEmptySelectionCopy() async -> Bool {
        await MainActor.run {
            // VS Code, Cursor and other Monaco-based editors copy the whole
            // current line when nothing is selected, and say so here.
            let type = NSPasteboard.PasteboardType("vscode-editor-data")
            guard let data = pasteboard.data(forType: type),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return (object["isFromEmptySelection"] as? Bool) == true
        }
    }

    public func writeTransient(_ text: String) async -> Int {
        await MainActor.run { TransientPasteboard.write(text, to: pasteboard) }
    }

    public func write(_ text: String) async {
        await MainActor.run {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
}
