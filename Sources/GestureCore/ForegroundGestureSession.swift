import Foundation

/// Allows a bounded, already-armed interaction to survive inactive foreground
/// transitions. This does not request background runtime or keep the display on.
struct ForegroundGestureSession {
    enum Phase: Equatable { case active, inactive, background }
    var engine = GestureEngine()
    private(set) var phase: Phase = .background
    private var lastSampleTime: Double?

    func allowsMotion(at now: Double) -> Bool {
        phase == .active || (phase == .inactive && engine.isArmed(at:now))
    }

    mutating func reset() {
        engine.reset()
        lastSampleTime = nil
    }

    mutating func calibrateAndArm(roll: Double, pitch: Double, sampleTime: Double, readyTime: Double) {
        engine.calibrateAndArm(roll:roll,pitch:pitch,sampleTime:sampleTime,readyTime:readyTime)
        lastSampleTime = sampleTime
    }

    /// Expiry is checked against delivery time, even if no sensor callbacks arrive.
    mutating func expireArm(at now: Double) {
        if engine.armedUntil.isFinite && !engine.isArmed(at:now) {
            engine.interruptMotion(at:now)
        }
    }

    @discardableResult
    mutating func transition(to next: Phase, at now: Double) -> Bool {
        phase = next
        expireArm(at:now)
        if !allowsMotion(at:now) { reset(); return false }
        return true
    }

    mutating func update(roll: Double, pitch: Double, acceleration: Double,
                         sampleTime: Double, now: Double, suppressActions: Bool = false) -> (accepted: Bool, event: GestureEngine.Event?) {
        expireArm(at:now)
        guard allowsMotion(at:now) else { reset(); return (false,nil) }
        guard [roll,pitch,acceleration,sampleTime,now].allSatisfy(\.isFinite), acceleration >= 0 else {
            reset()
            return (false,nil)
        }
        // Never replay queued motion after suspension or accept future/duplicate
        // timestamps. Keep the high-water mark until capture is explicitly reset.
        guard sampleTime <= now, now - sampleTime <= 0.25,
              lastSampleTime.map({sampleTime > $0}) ?? true else {
            engine.interruptMotion(at:now)
            return (false,nil)
        }
        if let previous = lastSampleTime, sampleTime - previous > 0.25 {
            engine.interruptMotion(at:now)
        }
        lastSampleTime = sampleTime
        return (true,engine.update(roll:roll,pitch:pitch,acceleration:acceleration,time:sampleTime,suppressActions:suppressActions))
    }
}
