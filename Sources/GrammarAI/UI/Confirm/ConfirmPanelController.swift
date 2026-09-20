import AppKit
import GrammarAICore
import SwiftUI

/// The optional "confirm before replacing" step: a keyboard-first panel
/// showing the original and the correction.
///
///     Return = Replace    Cmd+C = Copy    Esc = Cancel
///
/// The panel is non-activating: it takes the keyboard without making Grammar
/// AI the frontmost app, so the target app stays frontmost, keeps its
/// selection, and the paste lands where it should.
@MainActor
final class ConfirmPanelController: CorrectionConfirming {

    private var panel: KeyablePanel?
    private var continuation: CheckedContinuation<ConfirmationDecision, Never>?

    nonisolated func confirm(original: String, corrected: String) async -> ConfirmationDecision {
        await present(original: original, corrected: corrected)
    }

    private func present(original: String, corrected: String) async -> ConfirmationDecision {
        // One at a time: a stale panel is treated as cancelled.
        finish(.cancel)

        // "Cancel Correction" in the menu cancels the run's task; the panel
        // must then close as cancelled instead of waiting for a Return that
        // would still paste.
        let decision = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ConfirmationDecision, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .cancel)
                    return
                }
                self.continuation = continuation
                showPanel(original: original, corrected: corrected)
            }
        } onCancel: {
            Task { @MainActor in self.finish(.cancel) }
        }
        if decision == .replace {
            // Give the target app's window a moment to become key again
            // before the paste is posted.
            try? await Task.sleep(for: .milliseconds(180))
        }
        return decision
    }

    private func finish(_ decision: ConfirmationDecision) {
        panel?.orderOut(nil)
        panel = nil
        continuation?.resume(returning: decision)
        continuation = nil
    }

    private func showPanel(original: String, corrected: String) {
        let view = ConfirmView(original: original, corrected: corrected) { [weak self] decision in
            self?.finish(decision)
        }
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Review Correction"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = hosting
        panel.onCancel = { [weak self] in self?.finish(.cancel) }

        if let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + 80))
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }
}

/// A borderless-style panel that may become key, with Esc and the close
/// button both meaning "cancel".
final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func close() { onCancel?() }
}

private struct ConfirmView: View {
    let original: String
    let corrected: String
    let decide: (ConfirmationDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review Correction").font(.headline)

            block(title: "Original", text: original, emphasized: false)
            block(title: "Corrected", text: corrected, emphasized: true)

            HStack {
                Button("Cancel") { decide(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy") { decide(.copy) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Replace") { decide(.replace) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func block(title: String, text: String, emphasized: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(text)
                    .font(.body)
                    .foregroundStyle(emphasized ? .primary : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 130)
            .fixedSize(horizontal: false, vertical: true)
            .background(.quaternary.opacity(emphasized ? 0.9 : 0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
