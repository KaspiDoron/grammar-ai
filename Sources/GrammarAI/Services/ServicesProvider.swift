import AppKit
import GrammarAICore

/// "Correct with Grammar AI" in the right-click > Services menu.
///
/// macOS has no API for adding items to other apps' context menus; Services
/// is the native mechanism. The service declares a return type, so the host
/// app replaces the selection itself - natively and undoably, with no
/// clipboard and no synthesized keys. If anything fails we return nothing
/// and the host keeps the original text.
@MainActor
final class ServicesProvider: NSObject {

    /// Must match NSPortName in Info.plist.
    static let portName = "GrammarAI"

    private unowned let coordinator: AppCoordinator

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func register() {
        NSRegisterServicesProvider(self, Self.portName)
        NSUpdateDynamicServices()
    }

    /// Selector named by NSMessage in Info.plist. AppKit calls this on the
    /// main thread and the host app waits for it to return.
    @objc func correctSelection(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            error.pointee = CorrectionError.noSelection.userMessage as NSString
            return
        }
        guard coordinator.model.settings.isEnabled else {
            error.pointee = "Grammar AI is turned off." as NSString
            return
        }

        Log.info(.services, "service invoked")
        var result: Result<CorrectionResult, CorrectionError>?
        Task { @MainActor in
            result = await coordinator.correct(text: text)
        }
        // The service call is synchronous, but blocking the main thread
        // would deadlock the main-actor hops inside the pipeline. Spin the
        // run loop instead; the request itself times out after 30 s.
        let deadline = Date().addingTimeInterval(180)
        while result == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        switch result {
        case .success(let correction):
            guard correction.changed else {
                coordinator.showServiceMessage(UserMessage(kind: .success, text: "Already looks good"))
                return // Nothing written: the host keeps the text as is.
            }
            pasteboard.clearContents()
            pasteboard.setString(correction.correctedText, forType: .string)
        case .failure(let failure):
            Log.error(.services, "service failed", detail: failure.logDetail)
            error.pointee = failure.userMessage as NSString
            coordinator.showServiceMessage(UserMessage(kind: .failure, text: failure.userMessage))
        case nil:
            error.pointee = CorrectionError.timeout.userMessage as NSString
            coordinator.showServiceMessage(UserMessage(kind: .failure, text: CorrectionError.timeout.userMessage))
        }
    }
}
