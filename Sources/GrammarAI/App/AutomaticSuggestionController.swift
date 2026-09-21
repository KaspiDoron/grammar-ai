import AppKit
import GrammarAICore
import GrammarAISystem
import SwiftUI

/// The opt-in "suggest as you type" mode. It watches the focused text field
/// through Accessibility (never the keyboard), and when you pause after
/// finishing a sentence it quietly corrects that sentence with the free local
/// model and shows a small pill near the caret. It never changes your text on
/// its own - you accept with the shortcut, or keep typing to dismiss it.
///
/// Privacy: only the current sentence is sent, only to the local model, and
/// only while this mode is on.
@MainActor
final class AutomaticSuggestionController {

    /// A suggestion currently on screen, waiting to be accepted.
    private struct Pending {
        let field: FocusedTextField
        let sentence: SentenceExtractor.Sentence
        let corrected: String
    }

    private let monitor = AXTextMonitor()
    private let panel = SuggestionPanel()
    private let makeProvider: @Sendable () -> AITextCorrectionProvider
    private let context: @Sendable () -> CorrectionContext

    /// The shortcut shown on the pill (e.g. "⇧⌘G"). Updated by the coordinator.
    var hotkeyLabel = "\u{21E7}\u{2318}G"

    private var pending: Pending?
    private var correctTask: Task<Void, Never>?
    private var isEnabled = false

    init(
        makeProvider: @escaping @Sendable () -> AITextCorrectionProvider,
        context: @escaping @Sendable () -> CorrectionContext
    ) {
        self.makeProvider = makeProvider
        self.context = context

        monitor.onChange = { [weak self] field in self?.fieldChanged(field) }
        monitor.onFocusLost = { [weak self] in self?.dismiss() }
    }

    /// Turn the mode on or off. Off tears down the observer completely, so
    /// there is zero background work when it is not in use.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled, AccessibilityPermission.isGranted {
            monitor.start()
        } else {
            monitor.stop()
            dismiss()
        }
    }

    /// Whether a suggestion is showing (the coordinator asks this so the
    /// global shortcut accepts the suggestion instead of starting a new
    /// correction).
    var hasVisibleSuggestion: Bool { pending != nil }

    // MARK: - Producing a suggestion

    private func fieldChanged(_ field: FocusedTextField) {
        correctTask?.cancel()
        // Only act on a just-finished sentence, so we never interrupt a word.
        guard let sentence = SentenceExtractor.sentence(in: field.value, caret: field.caret) else {
            dismiss()
            return
        }
        // If we already suggested for this exact sentence, leave it.
        if let pending, pending.sentence == sentence { return }
        dismiss()

        let provider = makeProvider()
        let context = self.context()
        correctTask = Task { [weak self] in
            let raw = try? await provider.correct(text: sentence.text, context: context)
            guard let raw, !Task.isCancelled else { return }
            guard let validated = try? ResponseValidator.validate(raw, against: sentence.text, mode: context.mode),
                  validated.changed, !validated.needsReview else { return }
            self?.present(field: field, sentence: sentence, corrected: validated.correctedText)
        }
    }

    private func present(field: FocusedTextField, sentence: SentenceExtractor.Sentence, corrected: String) {
        pending = Pending(field: field, sentence: sentence, corrected: corrected)
        panel.show(corrected: corrected, hotkey: hotkeyLabel, near: field.caretBounds) { [weak self] in
            self?.accept()
        }
    }

    // MARK: - Accepting

    /// Applies the pending suggestion, if any. Returns true if it handled the
    /// event (so the shortcut does nothing else).
    @discardableResult
    func accept() -> Bool {
        guard let pending else { return false }
        let (newValue, caret) = SentenceExtractor.apply(pending.corrected, to: pending.sentence, in: pending.field.value)
        let outcome = AXTextWriter.setFocusedValue(newValue, caret: caret, expectedProcessID: pending.field.processID)
        dismiss()
        if outcome == .wrote {
            Log.info(.replace, "applied inline suggestion")
            return true
        }
        return false
    }

    func dismiss() {
        pending = nil
        correctTask?.cancel()
        correctTask = nil
        panel.hide()
    }
}

/// The small floating pill. Non-activating and click-through except for its
/// one button, so it never steals focus from the field you are typing in.
@MainActor
private final class SuggestionPanel {

    private var panel: NSPanel?
    private let state = PillState()

    func show(corrected: String, hotkey: String, near caretBounds: CGRect?, onAccept: @escaping () -> Void) {
        state.corrected = corrected
        state.hotkey = hotkey
        state.onAccept = onAccept

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let hosting = panel.contentView as? NSHostingView<PillView>
        hosting?.rootView = PillView(state: state)
        hosting?.layoutSubtreeIfNeeded()
        let size = hosting?.fittingSize ?? NSSize(width: 260, height: 44)

        let origin = position(for: size, near: caretBounds)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 },
            completionHandler: { [weak panel] in MainActor.assumeIsolated { if panel?.alphaValue == 0 { panel?.orderOut(nil) } } })
    }

    private func position(for size: NSSize, near caretBounds: CGRect?) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let caret = caretBounds, caret != .zero {
            // Just below the caret, nudged so it doesn't cover the line.
            var x = caret.minX
            var y = caret.minY - size.height - 6
            x = min(max(visible.minX + 8, x), visible.maxX - size.width - 8)
            if y < visible.minY + 8 { y = caret.maxY + 6 } // flip above if no room
            return NSPoint(x: x, y: y)
        }
        // No caret info: bottom-center, above the Dock.
        return NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 80)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: PillView(state: state))
        return panel
    }
}

@MainActor
private final class PillState: ObservableObject {
    @Published var corrected = ""
    @Published var hotkey = ""
    var onAccept: () -> Void = {}
}

private struct PillView: View {
    @ObservedObject var state: PillState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(state.corrected)
                .font(.system(size: 13))
                .lineLimit(2)
                .frame(maxWidth: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: state.onAccept) {
                Text("\(state.hotkey) to fix")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .padding(10)
        .fixedSize()
    }
}
