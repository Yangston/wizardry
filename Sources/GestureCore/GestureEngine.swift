import Foundation

/// Relative-angle gestures with a deliberate four-excursion wake sequence.
/// A wake only arms; it never triggers an action. All times are monotonic seconds.
struct GestureEngine {
    enum Event: Equatable { case woke, action(GestureKind) }
    private(set) var relativeRoll = 0.0
    private(set) var relativePitch = 0.0
    private(set) var armedUntil = -Double.infinity
    private var baseline: (Double, Double)?
    private var lastTime: Double?
    private var wakeSigns: [Int] = []
    private var wakeStarted = 0.0
    private var lastSign = 0
    private var mustSettle = true
    private var neutralSince: Double?
    private var candidate: GestureKind?
    private var candidateSince = 0.0
    private var lastFire = -Double.infinity
    private var firstShake: Double?
    private var aboveShake = false
    var requireWake = true
    var threshold = 0.65
    var armSeconds = 8.0

    var isArmed: Bool { (lastTime ?? 0) < armedUntil }
    func isArmed(at time: Double) -> Bool { time.isFinite && time < armedUntil }
    mutating func reset() {
        let wake = requireWake, angle = threshold, seconds = armSeconds
        self = Self(); requireWake = wake; threshold = angle; armSeconds = seconds
    }
    /// Discard incomplete gestures after a delivery interruption, retaining the
    /// calibrated neutral position, cooldown, and only the unexpired arm deadline.
    mutating func interruptMotion(at time: Double) {
        let origin = baseline, deadline = armedUntil, previousFire = lastFire
        reset()
        baseline = origin
        lastFire = previousFire
        if time.isFinite && time < deadline { armedUntil = deadline }
    }
    mutating func arm(time: Double) {
        armedUntil = time + armSeconds
        mustSettle = true; neutralSince = nil; candidate = nil; firstShake = nil
        wakeSigns = []; lastSign = 0
    }
    /// Only call after the launcher has observed a stable wrist for 250 ms.
    /// The ready haptic means the next deliberate gesture can act immediately.
    mutating func calibrateAndArm(roll: Double, pitch: Double, sampleTime: Double, readyTime: Double) {
        reset()
        guard [roll, pitch, sampleTime, readyTime].allSatisfy(\.isFinite), readyTime >= sampleTime else { return }
        baseline = (roll, pitch)
        lastTime = sampleTime
        arm(time: readyTime)
        mustSettle = false
    }
    mutating func update(roll: Double, pitch: Double, acceleration: Double, time: Double) -> Event? {
        guard [roll,pitch,acceleration,time].allSatisfy(\.isFinite) else { reset(); return nil }
        if let previous = lastTime, time <= previous || time - previous > 0.25 { reset() }
        lastTime = time
        guard let origin = baseline else { baseline = (roll,pitch); return nil }
        relativeRoll = atan2(sin(roll-origin.0), cos(roll-origin.0))
        relativePitch = atan2(sin(pitch-origin.1), cos(pitch-origin.1))
        let neutral = abs(relativeRoll) < 0.18 && abs(relativePitch) < 0.18 && acceleration < 0.35
        if requireWake && !isArmed {
            mustSettle = true; candidate = nil; firstShake = nil
            if time - wakeStarted > 2.5 { wakeSigns = []; lastSign = 0 }
            let sign = relativeRoll > 0.45 ? 1 : (relativeRoll < -0.45 ? -1 : 0)
            if sign != 0 && sign != lastSign {
                if wakeSigns.isEmpty { wakeStarted = time }
                wakeSigns.append(sign); lastSign = sign
                if wakeSigns.count == 4 { arm(time: time); return .woke }
            }
            return nil
        }
        if mustSettle {
            if neutral {
                if neutralSince == nil { neutralSince = time }
                if time - (neutralSince ?? time) >= 0.25 && time - lastFire >= 0.8 {
                    mustSettle = false; neutralSince = nil; aboveShake = false
                }
            } else { neutralSince = nil }
            return nil
        }
        if acceleration > 1.2 && !aboveShake {
            aboveShake = true
            if let first = firstShake, (0.12...0.65).contains(time-first) { return fire(.shake, time: time) }
            firstShake = time
        } else if acceleration < 0.45 { aboveShake = false }
        if let first = firstShake, time-first > 0.65 { firstShake = nil }
        var gesture: GestureKind?
        if abs(relativeRoll) >= threshold && abs(relativeRoll) > abs(relativePitch) * 1.2 {
            gesture = relativeRoll > 0 ? .rollPositive : .rollNegative
        } else if abs(relativePitch) >= threshold && abs(relativePitch) > abs(relativeRoll) * 1.2 {
            gesture = relativePitch > 0 ? .pitchUp : .pitchDown
        }
        guard let gesture else { candidate = nil; return nil }
        if candidate != gesture { candidate = gesture; candidateSince = time }
        guard time-candidateSince >= 0.12 else { return nil }
        return fire(gesture,time: time)
    }
    private mutating func fire(_ gesture: GestureKind, time: Double) -> Event {
        lastFire = time; mustSettle = true; neutralSince = nil; candidate = nil; firstShake = nil
        return .action(gesture)
    }
}
