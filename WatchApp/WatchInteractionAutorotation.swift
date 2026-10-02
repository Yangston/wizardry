import OSLog
import WatchKit

/// Temporarily enables watchOS's wrist-flip presentation behavior for a bounded
/// interaction. This does not request extended or background execution time.
@MainActor
final class WatchInteractionAutorotation: InteractionRuntimeDriver {
    var didStart: (() -> Void)?
    var didStop: ((String) -> Void)?
    private var enabled = false
    private let logger = Logger(subsystem:"com.yangston.wizardry",category:"InteractionAutorotation")

    func start() {
        guard WKApplication.shared().applicationState == .active else {
            didStop?("Raise your wrist · activate again")
            return
        }
        WKApplication.shared().isAutorotating = true
        enabled = true
        logger.info("Interaction autorotation enabled")
        didStart?()
    }

    func invalidate() {
        guard enabled else { return }
        enabled = false
        WKApplication.shared().isAutorotating = false
        logger.info("Interaction autorotation disabled")
    }
}
