import Foundation

/// One foreground launch request. All times use the system uptime clock.
/// No launch samples are sent to GestureEngine until calibration completes.
struct ShortcutActivation {
    enum State: Equatable { case idle, waitingForForeground, calibrating }
    enum Event: Equatable { case ready, timedOut, invalidMotion }

    static let timeout = 10.0
    static let stableDuration = 0.25
    private(set) var state: State = .idle
    private var deadline = 0.0
    private var captureStarted = 0.0
    private var stableSince: Double?
    private var lastSample: Double?

    var isPending: Bool { state != .idle }

    mutating func request(at time: Double) {
        cancel()
        guard time.isFinite else { return }
        deadline = time + Self.timeout
        state = .waitingForForeground
    }

    @discardableResult
    mutating func beginCapture(at time: Double) -> Bool {
        guard !expire(at: time), state == .waitingForForeground else { return false }
        captureStarted = time
        state = .calibrating
        return true
    }

    /// Initial inactive/foreground transitions must not discard a cold launch.
    mutating func leaveForeground() {
        if state == .calibrating { cancel() }
    }

    mutating func cancel() { self = Self() }

    @discardableResult
    mutating func expire(at time: Double) -> Bool {
        guard isPending, !time.isFinite || time >= deadline else { return false }
        cancel()
        return true
    }

    mutating func update(roll: Double, pitch: Double, acceleration: Double,
                         rotationRate: Double, sampleTime: Double, now: Double) -> Event? {
        guard isPending else { return nil }
        if expire(at: now) { return .timedOut }
        guard state == .calibrating else { return nil }
        guard [roll, pitch, acceleration, rotationRate, sampleTime].allSatisfy(\.isFinite),
              acceleration >= 0, rotationRate >= 0 else {
            cancel()
            return .invalidMotion
        }

        // Ignore buffered samples from before capture and stale delivery. A gap
        // or a repeated timestamp cannot count as time spent holding still.
        guard sampleTime >= captureStarted, sampleTime <= now, now - sampleTime <= 0.25 else {
            stableSince = nil
            lastSample = nil
            return nil
        }
        if let previous = lastSample, sampleTime <= previous {
            stableSince = nil
            return nil
        }
        if let previous = lastSample, sampleTime - previous > 0.25 { stableSince = nil }
        lastSample = sampleTime

        // Acceleration is measured in g, rotation rate in radians per second.
        guard acceleration < 0.1, rotationRate < 0.2 else {
            stableSince = nil
            return nil
        }
        if stableSince == nil { stableSince = sampleTime }
        guard sampleTime - (stableSince ?? sampleTime) >= Self.stableDuration else { return nil }
        cancel()
        return .ready
    }
}
