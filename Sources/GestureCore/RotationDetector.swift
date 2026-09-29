import Foundation

/// Deliberate relative roll, followed by return to the starting pose before rearming.
/// Angles are radians; time is a monotonic sensor timestamp, in seconds.
struct RotationDetector {
    enum Gesture: String { case positive = "Rotate +", negative = "Rotate −" }
    private(set) var relativeRoll = 0.0
    private var baseline: Double?
    private var lastTime: Double?
    private var candidate: Gesture?
    private var candidateSince = 0.0
    private var firedAt: Double?
    private var neutralSince: Double?

    mutating func reset() { self = RotationDetector() }

    mutating func update(roll: Double, time: Double) -> Gesture? {
        guard roll.isFinite, time.isFinite else { reset(); return nil }
        if let previous = lastTime, time <= previous || time - previous > 0.25 {
            reset()
        }
        lastTime = time
        guard let origin = baseline else { baseline = roll; return nil }
        relativeRoll = atan2(sin(roll - origin), cos(roll - origin))
        if let fired = firedAt {
            if abs(relativeRoll) < 0.15 {
                if neutralSince == nil { neutralSince = time }
                if time - (neutralSince ?? time) >= 0.25 && time - fired >= 1.0 {
                    firedAt = nil
                    neutralSince = nil
                }
            } else { neutralSince = nil }
            return nil
        }
        guard abs(relativeRoll) >= 0.65 else { candidate = nil; return nil }
        let direction: Gesture = relativeRoll > 0 ? .positive : .negative
        if candidate != direction { candidate = direction; candidateSince = time }
        guard time - candidateSince >= 0.12 else { return nil }
        candidate = nil
        firedAt = time
        return direction
    }
}
