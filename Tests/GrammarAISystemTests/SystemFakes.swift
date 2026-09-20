import Foundation
import GrammarAICore
@testable import GrammarAISystem

/// An in-memory clipboard. Tests never touch the user's real one.
final class FakeClipboard: ClipboardAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var text: String?
    private var count = 0
    private var emptySelectionCopy = false
    private(set) var log: [String] = []

    init(text: String? = nil) { self.text = text }

    var currentText: String? { lock.withLock { text } }

    /// Simulates an app (or the user) writing to the clipboard.
    func externalWrite(_ value: String?, emptySelectionCopy: Bool = false) {
        lock.withLock {
            text = value
            count += 1
            self.emptySelectionCopy = emptySelectionCopy
        }
    }

    func changeCount() async -> Int { lock.withLock { count } }
    func snapshot() async -> PasteboardSnapshot {
        lock.withLock {
            log.append("snapshot")
            guard let text else { return PasteboardSnapshot(items: []) }
            return PasteboardSnapshot(items: [.init(representations: [("public.utf8-plain-text", Data(text.utf8))])])
        }
    }
    func restore(_ snapshot: PasteboardSnapshot) async {
        lock.withLock {
            log.append("restore")
            text = snapshot.items.first?.representations.first.map { String(decoding: $0.data, as: UTF8.self) }
            count += 1
            emptySelectionCopy = false
        }
    }
    func plainText() async -> String? { lock.withLock { text } }
    func isEmptySelectionCopy() async -> Bool { lock.withLock { emptySelectionCopy } }
    func writeTransient(_ value: String) async -> Int {
        lock.withLock {
            log.append("writeTransient")
            text = value
            count += 1
            return count
        }
    }
    func write(_ value: String) async {
        lock.withLock {
            log.append("write")
            text = value
            count += 1
        }
    }
}

final class FakeKeys: KeySimulating, @unchecked Sendable {
    var isSecureInputActive = false
    var onCopy: (@Sendable () -> Void)?
    var onPaste: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var _posted: [String] = []
    var posted: [String] { lock.withLock { _posted } }

    func waitForModifierRelease(timeout: TimeInterval) async {}
    func postCopy() async {
        lock.withLock { _posted.append("copy") }
        onCopy?()
    }
    func postPaste() async {
        lock.withLock { _posted.append("paste") }
        onPaste?()
    }
}

/// Scripted Accessibility answers, returned in order (the last one repeats).
final class FakeAX: AXSelectionReading, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [AXSelectionResult]
    init(_ script: AXSelectionResult...) { self.script = script }

    func readSelection(processID: pid_t?) -> AXSelectionResult {
        lock.withLock { script.count > 1 ? script.removeFirst() : (script.first ?? .unavailable) }
    }
}

struct FakeFrontmost: FrontmostAppProviding {
    var app: FrontmostApp? = FrontmostApp(processID: 42, bundleID: "com.example.editor", name: "Editor")
    func current() async -> FrontmostApp? { app }
}
