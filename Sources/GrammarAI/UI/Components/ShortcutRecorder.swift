import AppKit
import Carbon.HIToolbox
import GrammarAICore
import GrammarAISystem
import SwiftUI

/// Click, press a shortcut, done. Esc cancels, Delete clears.
///
/// Recording uses a LOCAL event monitor, which only sees keys typed into our
/// own Settings window - Grammar AI never observes keys typed elsewhere.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    /// Lets the owner suspend the live global shortcut while recording.
    var onRecordingChanged: (Bool) -> Void = { _ in }

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var observers: [NSObjectProtocol] = []
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Text(label)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .frame(minWidth: 120)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)
            .accessibilityLabel("Global shortcut")
            .accessibilityValue(combo?.localizedSpokenDescription ?? "None")
            .accessibilityHint("Press to record a new shortcut")

            if combo != nil, !isRecording {
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove the shortcut")
                .accessibilityLabel("Remove shortcut")
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.orange).offset(y: 18)
            }
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if isRecording { return "Type shortcut..." }
        return combo?.localizedDisplayString ?? "Record Shortcut"
    }

    private func toggle() {
        isRecording ? stop() : start()
    }

    private func start() {
        guard monitor == nil else { return }
        isRecording = true
        hint = nil
        onRecordingChanged(true)
        let recordingWindow = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Keys typed into another of our windows are none of our business.
            guard event.window === recordingWindow else { return event }
            MainActor.assumeIsolated { handle(event) }
            return nil // Swallow it: the key must not type into the form.
        }
        // Recording suspends the live global shortcut. If the user wanders
        // off without pressing a key, end it - otherwise the shortcut would
        // stay dead with nothing to show for it.
        let center = NotificationCenter.default
        let names: [(Notification.Name, Any?)] = [
            (NSWindow.didResignKeyNotification, recordingWindow),
            (NSWindow.willCloseNotification, recordingWindow),
            (NSApplication.didResignActiveNotification, nil)
        ]
        observers = names.map { name, object in
            center.addObserver(forName: name, object: object, queue: .main) { _ in
                MainActor.assumeIsolated { stop() }
            }
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard isRecording else { return }
        isRecording = false
        onRecordingChanged(false)
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = UInt32(event.keyCode)

        if keyCode == UInt32(kVK_Escape), flags.isDisjoint(with: [.command, .control, .option]) {
            stop()
            return
        }
        if keyCode == UInt32(kVK_Delete) || keyCode == UInt32(kVK_ForwardDelete),
           flags.isDisjoint(with: [.command, .control, .option, .shift]) {
            combo = nil
            stop()
            return
        }

        var modifiers: KeyCombo.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }

        let candidate = KeyCombo(keyCode: keyCode, modifiers: modifiers)
        guard candidate.isValidGlobalShortcut else {
            hint = "Include Command, Control or Option."
            return
        }
        combo = candidate
        stop()
    }
}
