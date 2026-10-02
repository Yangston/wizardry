import Foundation

/// The platform adapter owns the OS session; this controller owns its bounded
/// interaction lifetime. Late callbacks from a previous activation are ignored.
@MainActor
protocol InteractionRuntimeDriver: AnyObject {
    var didStart: (() -> Void)? { get set }
    var didStop: ((String) -> Void)? { get set }
    func start()
    func invalidate()
}

@MainActor
final class InteractionRuntime {
    private let makeDriver: () -> any InteractionRuntimeDriver
    private let clock: () -> Double
    private var driver: (any InteractionRuntimeDriver)?
    private var maximumDeadline: Double?
    private(set) var deadline: Double?
    private(set) var isRunning = false
    var isRequested: Bool { driver != nil }
    var interrupted: ((String) -> Void)?

    init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         makeDriver: @escaping () -> any InteractionRuntimeDriver) {
        self.clock = clock
        self.makeDriver = makeDriver
    }

    @discardableResult
    func start(until requestedDeadline: Double, canStart: Bool) -> Bool {
        stop()
        let now = clock()
        guard canStart, now.isFinite, requestedDeadline.isFinite, requestedDeadline > now else {
            interrupted?("Runtime unavailable · activate again with the watch awake")
            return false
        }
        // Self-care sessions have a 10-minute OS limit. Never renew a session
        // automatically, even if a live volume interaction keeps moving.
        let limit = now + 10 * 60
        maximumDeadline = limit
        deadline = min(requestedDeadline, limit)
        let next = makeDriver()
        driver = next
        next.didStart = { [weak self, weak next] in
            guard let self, let next, self.driver === next else { return }
            if !self.expireIfNeeded() { self.isRunning = true }
        }
        next.didStop = { [weak self, weak next] message in
            guard let self, let next, self.driver === next else { return }
            self.stop()
            self.interrupted?(message)
        }
        next.start()
        return driver === next
    }

    /// Volume takes over the same activation; it never starts another OS session.
    /// Its own lock, inactivity and interruption checks end this lease early.
    @discardableResult
    func continueThroughVolume(until sessionDeadline: Double) -> Bool {
        guard !expireIfNeeded(), driver != nil, let maximumDeadline, sessionDeadline.isFinite else { return false }
        deadline = min(sessionDeadline, maximumDeadline)
        return !expireIfNeeded()
    }

    @discardableResult
    func expireIfNeeded() -> Bool {
        guard let deadline else { return false }
        let now = clock()
        guard !now.isFinite || now >= deadline else { return false }
        stop()
        interrupted?("Interaction runtime expired · activate again")
        return true
    }

    func stop() {
        let previous = driver
        driver = nil; deadline = nil; maximumDeadline = nil; isRunning = false
        previous?.didStart = nil; previous?.didStop = nil
        previous?.invalidate()
    }
}
