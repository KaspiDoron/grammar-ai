import AppKit
import SwiftUI

/// A small floating status pill: "Correcting...", "Corrected", or an error.
///
/// It is a non-activating, click-through panel, so it can never steal focus
/// from the app the user is typing in - which would also break the paste.
@MainActor
final class HUDController {

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func showProgress(_ text: String) {
        hideTask?.cancel()
        present(.progress(text))
    }

    func show(_ message: UserMessage) {
        hideTask?.cancel()
        present(.message(message))
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message.text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        // Long enough to read: errors and explanations stay up longer.
        let seconds: Double = message.kind == .success ? 1.3 : min(6, 2.2 + Double(message.text.count) / 28)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            MainActor.assumeIsolated {
                // A newer message may have faded back in meanwhile.
                if let panel, panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        })
    }

    // MARK: - Panel

    private func present(_ content: HUDContent) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Size to the content, then sit bottom-center of the screen the user
        // is working on, above the Dock. The view takes a plain value (not
        // observed state), so the size measured here is already up to date.
        let hosting = panel.contentView as? NSHostingView<HUDView>
        hosting?.rootView = HUDView(content: content)
        hosting?.layoutSubtreeIfNeeded()
        let size = hosting?.fittingSize ?? NSSize(width: 220, height: 44)
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 96)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }

        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDView(content: .progress("")))
        return panel
    }
}

enum HUDContent: Equatable {
    case progress(String)
    case message(UserMessage)
}

struct HUDView: View {
    let content: HUDContent

    var body: some View {
        HStack(spacing: 10) {
            icon
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(isLong ? 3 : 1)
                .multilineTextAlignment(.leading)
                // A definite width for long messages so they wrap; short
                // ones take exactly the room they need.
                .frame(width: isLong ? 300 : nil, alignment: .leading)
                .fixedSize(horizontal: !isLong, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: isLong ? 16 : 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: isLong ? 16 : 22, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .padding(12) // room for the shadow
        .accessibilityElement(children: .combine)
    }

    private var isLong: Bool { text.count > 44 }

    private var text: String {
        switch content {
        case .progress(let text): return text
        case .message(let message): return message.text
        }
    }

    @ViewBuilder private var icon: some View {
        switch content {
        case .progress:
            ProgressView().controlSize(.small)
        case .message(let message):
            switch message.kind {
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .info:
                Image(systemName: "doc.on.clipboard.fill").foregroundStyle(.blue)
            case .failure:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }
}
