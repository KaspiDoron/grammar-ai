import Foundation

/// Delays used by capture and replacement. A struct so tests can shrink them
/// to zero and run instantly.
public struct SystemTiming: Sendable {
    /// How long to wait for the user to let go of the hotkey's modifiers.
    public var modifierReleaseTimeout: TimeInterval
    /// How long a Cmd+C may take to reach the pasteboard.
    public var copyTimeout: TimeInterval
    /// Apps clear the pasteboard, then write; let the write land.
    public var copySettle: TimeInterval
    /// Never restore the clipboard sooner than this after Cmd+V.
    public var pasteFloor: TimeInterval
    /// Stop waiting for Accessibility to confirm the paste after this long.
    public var pasteCap: TimeInterval
    /// Wait after Cmd+V when Accessibility cannot observe the target app.
    public var pasteBlindWait: TimeInterval
    /// After a Cmd+C that produced nothing in time, how long to keep watching
    /// for it to land late, so the user's clipboard can be put back.
    public var lateCopyGrace: TimeInterval
    public var pollInterval: TimeInterval

    public init(
        modifierReleaseTimeout: TimeInterval = 0.7,
        copyTimeout: TimeInterval = 0.6,
        copySettle: TimeInterval = 0.03,
        pasteFloor: TimeInterval = 0.35,
        pasteCap: TimeInterval = 1.2,
        pasteBlindWait: TimeInterval = 0.7,
        lateCopyGrace: TimeInterval = 2.5,
        pollInterval: TimeInterval = 0.015
    ) {
        self.modifierReleaseTimeout = modifierReleaseTimeout
        self.copyTimeout = copyTimeout
        self.copySettle = copySettle
        self.pasteFloor = pasteFloor
        self.pasteCap = pasteCap
        self.pasteBlindWait = pasteBlindWait
        self.lateCopyGrace = lateCopyGrace
        self.pollInterval = pollInterval
    }

    public static let standard = SystemTiming()

    /// For tests.
    public static let immediate = SystemTiming(
        modifierReleaseTimeout: 0, copyTimeout: 0.05, copySettle: 0,
        pasteFloor: 0, pasteCap: 0.05, pasteBlindWait: 0, lateCopyGrace: 0, pollInterval: 0.001
    )
}

/// Reads the selection the universal way: save the clipboard, press Cmd+C,
/// read what arrived, put the clipboard back. Used when an app exposes
/// nothing through Accessibility (Chromium, Electron, Google Docs).
struct ClipboardSelectionCopier: Sendable {

    let clipboard: ClipboardAccessing
    let keys: KeySimulating
    let timing: SystemTiming

    /// Returns the selected text, or nil when nothing was selected. The
    /// user's clipboard is restored before this returns, on every path.
    func copySelection() async -> String? {
        let saved = await clipboard.snapshot()
        let before = await clipboard.changeCount()

        await keys.waitForModifierRelease(timeout: timing.modifierReleaseTimeout)
        await keys.postCopy()

        guard await waitForChange(from: before) else {
            // Nothing arrived in time. Usually that means nothing was
            // selected - but a busy app may still service our Cmd+C a moment
            // later and overwrite the user's clipboard. Keep watching for a
            // little while, off to the side, and undo that if it happens.
            restoreIfCopyArrivesLate(saved: saved, before: before)
            return nil
        }
        await pause(timing.copySettle)

        let afterCopy = await clipboard.changeCount()
        let wasEmptySelectionCopy = await clipboard.isEmptySelectionCopy()
        let text = await clipboard.plainText()

        // Put the user's clipboard back - unless they (or another app) wrote
        // to it in the meantime, in which case theirs wins.
        if await clipboard.changeCount() == afterCopy {
            await clipboard.restore(saved)
        }

        guard !wasEmptySelectionCopy, let text, !text.isEmpty else { return nil }
        return text
    }

    private func restoreIfCopyArrivesLate(saved: PasteboardSnapshot, before: Int) {
        guard timing.lateCopyGrace > 0 else { return }
        let clipboard = self.clipboard
        let timing = self.timing
        Task.detached {
            let deadline = Date().addingTimeInterval(timing.lateCopyGrace)
            while Date() < deadline {
                await pause(0.05)
                let now = await clipboard.changeCount()
                guard now != before else { continue }
                await pause(timing.copySettle)
                // Only undo our own late copy - exactly one change since.
                if await clipboard.changeCount() == now {
                    await clipboard.restore(saved)
                }
                return
            }
        }
    }

    private func waitForChange(from before: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(timing.copyTimeout)
        repeat {
            if await clipboard.changeCount() != before { return true }
            await pause(timing.pollInterval)
        } while Date() < deadline && !Task.isCancelled
        return await clipboard.changeCount() != before
    }
}

/// A sleep that a cancelled task cannot turn into a busy loop or an early
/// exit: the clipboard must be restored even when the run was cancelled.
func pause(_ interval: TimeInterval) async {
    guard interval > 0 else { return }
    let nanoseconds = UInt64(interval * 1_000_000_000)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
            continuation.resume()
        }
    }
}
