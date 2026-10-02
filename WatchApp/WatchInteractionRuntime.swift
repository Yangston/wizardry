import Foundation
import OSLog
import WatchKit

/// This experiment uses the self-care capability for a short frontmost session.
/// It provides execution time, not a display-awake override.
@MainActor
final class WatchInteractionRuntime: NSObject, InteractionRuntimeDriver, WKExtendedRuntimeSessionDelegate {
    var didStart: (() -> Void)?
    var didStop: ((String) -> Void)?
    private var session: WKExtendedRuntimeSession?
    private let logger = Logger(subsystem:"com.yangston.wizardry",category:"InteractionRuntime")

    func start() {
        guard WKApplication.shared().applicationState == .active else {
            didStop?("Runtime needs an awake watch · activate again")
            return
        }
        let next = WKExtendedRuntimeSession()
        session = next
        next.delegate = self
        logger.info("Requesting bounded interaction runtime")
        next.start()
    }

    func invalidate() {
        let previous = session
        session = nil
        if previous != nil { logger.info("Ending interaction runtime") }
        previous?.invalidate()
    }

    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor [weak self] in
            guard let self, self.session === extendedRuntimeSession else { return }
            self.logger.info("Interaction runtime started")
            self.didStart?()
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor [weak self] in
            guard let self, self.session === extendedRuntimeSession else { return }
            self.logger.info("Interaction runtime will expire")
            self.didStop?("Watch runtime ending · activate again")
        }
    }

    nonisolated func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                           didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                           error: Error?) {
        // Expose the OS reason without treating loss of runtime as a new activation.
        let message = "Watch ended sensing · activate again"
        let details = error?.localizedDescription ?? "No error supplied"
        Task { @MainActor [weak self] in
            guard let self, self.session === extendedRuntimeSession else { return }
            self.session = nil
            self.logger.info("Interaction runtime invalidated, reason: \(reason.rawValue)")
            self.logger.debug("Runtime invalidation details: \(details)")
            self.didStop?(message)
        }
    }
}
