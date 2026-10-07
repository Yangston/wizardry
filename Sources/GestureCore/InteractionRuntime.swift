import Foundation

/// The platform adapter enables an interaction aid (currently autorotation);
/// this controller bounds its lifetime and ignores previous activation callbacks.
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
    /// Capture evidence before releasing the platform aid, including expiry.
    var willStop: ((InteractionEndReason) -> Void)?
    var didStop: (() -> Void)?

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
            interrupted?("Raise your wrist · activate again")
            return false
        }
        // Keep the existing ten-minute interaction cap so autorotation cannot
        // remain enabled indefinitely during sustained volume movement.
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
            self.stop(reason:.systemStopped)
            self.interrupted?(message)
        }
        next.start()
        return driver === next
    }

    /// Volume takes over the same activation without toggling the platform aid.
    /// Explicit lock and interruption checks end this lease early. A stationary
    /// hand is not an interruption and does not shorten the lease.
    @discardableResult
    func continueThroughVolume(until sessionDeadline: Double) -> Bool {
        continueInteraction(until:sessionDeadline)
    }

    /// Calibration and readiness share one lease, without a disable/enable gap.
    @discardableResult
    func continueThroughArming(until armDeadline: Double) -> Bool {
        continueInteraction(until:armDeadline)
    }

    private func continueInteraction(until sessionDeadline: Double) -> Bool {
        guard !expireIfNeeded(), driver != nil, let maximumDeadline, sessionDeadline.isFinite else { return false }
        deadline = min(sessionDeadline, maximumDeadline)
        return !expireIfNeeded()
    }

    @discardableResult
    func expireIfNeeded() -> Bool {
        guard let deadline else { return false }
        let now = clock()
        guard !now.isFinite || now >= deadline else { return false }
        stop(reason:.runtimeExpired)
        interrupted?("Interaction ended · activate again")
        return true
    }

    func stop(reason: InteractionEndReason = .replaced) {
        let previous = driver
        if previous != nil { willStop?(reason) }
        driver = nil; deadline = nil; maximumDeadline = nil; isRunning = false
        previous?.didStart = nil; previous?.didStop = nil
        previous?.invalidate()
        if previous != nil { didStop?() }
    }
}
