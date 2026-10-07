import Foundation

struct MotionVector: Codable, Equatable {
    var x: Double; var y: Double; var z: Double
    var length: Double { sqrt(dot(self)) }
    var isFinite: Bool { [x,y,z].allSatisfy(\.isFinite) }
    func dot(_ other: Self) -> Double { x*other.x + y*other.y + z*other.z }
}

struct MotionQuaternion: Codable, Equatable {
    var x: Double; var y: Double; var z: Double; var w: Double
    var normal: MotionVector? {
        let norm = sqrt(x*x+y*y+z*z+w*w)
        guard norm.isFinite, norm > 0.0001 else { return nil }
        let a = x/norm, b = y/norm, c = z/norm, d = w/norm
        return .init(x:2*(a*c+d*b), y:2*(b*c-d*a), z:1-2*(a*a+b*b))
    }
}

/// Extension follows the measured z/yaw change from the ready pose. Comparing
/// face normals misses pure z rotation entirely. Signed wrap supports either
/// wrist and a ready heading that is not zero.
struct ExtensionArbiter {
    enum Route: Equatable { case transition, legacy, enterVolume }
    private var viewingYaw: Double?
    private var stableYaw: Double?
    private var stableSince: Double?
    private var lastTime: Double?
    private var needsRebase = false
    static let entryAngle = 55 * Double.pi/180
    private(set) var relativeYaw = 0.0
    var angle: Double { abs(relativeYaw) }
    mutating func calibrate(yaw: Double) {
        self = Self(); if yaw.isFinite { viewingYaw = yaw }
    }
    static func offset(_ angle: Double, from origin: Double) -> Double {
        atan2(sin(angle-origin),cos(angle-origin))
    }
    func yawOffset(_ yaw: Double) -> Double? {
        guard let origin = viewingYaw, yaw.isFinite else { return nil }
        return Self.offset(yaw,from:origin)
    }
    func isViewing(yaw: Double) -> Bool {
        yawOffset(yaw).map {abs($0) < 25 * .pi/180} ?? false
    }
    mutating func interruptMotion() {
        stableYaw = nil; stableSince = nil; lastTime = nil; needsRebase = true
    }
    mutating func update(yaw: Double, acceleration: Double, rotation: Double, time: Double) -> Route {
        guard let offset = yawOffset(yaw),
              [acceleration,rotation,time].allSatisfy(\.isFinite), acceleration >= 0, rotation >= 0 else {
            interruptMotion(); return .transition
        }
        if let previous = lastTime, time <= previous {
            stableYaw = nil; stableSince = nil; return .transition
        }
        let gap = lastTime.map { time-$0 > 0.25 } ?? false
        lastTime = time
        relativeYaw = offset
        if gap || needsRebase {
            stableYaw = nil; stableSince = nil; needsRebase = false
            return .transition
        }
        // Claim extension on the first fresh sample crossing 55 degrees. Entry
        // does not wait for the arm to stop or require a particular rotation rate.
        if angle + 0.000000001 >= Self.entryAngle { return .enterVolume }
        if angle >= 25 * .pi/180 {
            stableYaw = nil; stableSince = nil; return .transition
        }
        // Shakes near the viewing pose retain their existing discrete recognizer.
        if angle < 25 * .pi/180, rotation < 0.8, acceleration >= 0.1 { return .legacy }
        guard acceleration < 0.1, rotation < 0.2 else {
            stableSince = nil; stableYaw = nil; return .transition
        }
        if stableYaw.map({abs(Self.offset(yaw,from:$0)) > 3 * .pi/180}) ?? true {
            stableYaw = yaw; stableSince = time
        }
        guard time - (stableSince ?? time) >= 0.25 else { return .transition }
        return .legacy
    }
}

/// A relative roll knob anchored to actual volume at entry. Each signed, wrapped
/// increment changes volume immediately: 180 degrees spans the full volume range.
struct TwistVolumeTracker {
    private(set) var target = 0.0
    private(set) var startingVolume = 0.0
    private(set) var twistRadians = 0.0
    private(set) var angularVelocity = 0.0
    private var lastRoll: Double?
    private var lastTime: Double?
    mutating func begin(volume: Double, roll: Double, time: Double) {
        self = Self()
        target = volume.isFinite ? min(1,max(0,volume)) : 0
        startingVolume = target
        freeze(roll:roll,time:time)
    }
    mutating func freeze(roll: Double, time: Double) {
        angularVelocity = 0
        guard roll.isFinite, time.isFinite else {
            lastRoll = nil; lastTime = nil; return
        }
        lastRoll = roll; lastTime = time
    }
    mutating func update(roll: Double, time: Double, frozen: Bool = false) -> Double {
        guard roll.isFinite, time.isFinite else {
            lastRoll = nil; lastTime = nil; angularVelocity = 0; return target
        }
        guard let previousTime = lastTime, let previousRoll = lastRoll else {
            freeze(roll:roll,time:time); return target
        }
        guard time > previousTime else {
            lastRoll = nil; lastTime = nil; angularVelocity = 0; return target
        }
        guard time-previousTime <= 0.25, !frozen else {
            freeze(roll:roll,time:time); return target
        }
        let delta = ExtensionArbiter.offset(roll,from:previousRoll)
        angularVelocity = delta/(time-previousTime)
        twistRadians += delta
        // Clamp each increment, so turning back from a limit responds at once
        // even after further outward rotation. There is no accumulated windup.
        target = min(1,max(0,target+delta / .pi))
        lastRoll = roll; lastTime = time
        return target
    }
}

struct VolumeRequest: Codable, Equatable {
    enum Operation: String, Codable { case begin, update, end }
    var id = UUID()
    var sessionID: UUID
    var revision: String
    var sequence: Int
    var createdAt = Date().timeIntervalSince1970
    var operation: Operation
    var target: Double?
    var profileID: String? = nil
    var isValid: Bool {
        createdAt.isFinite && sequence >= 0 && !revision.isEmpty &&
        (profileID.map { ["computer","phone"].contains($0) } ?? true) &&
        (operation == .begin ? sequence == 0 && target == nil : sequence > 0 &&
         (target.map({$0.isFinite && (0...1).contains($0)}) ?? false))
    }
}

struct VolumeReply: Codable {
    enum Disposition: String, Codable { case applied, superseded }
    var outcome: ActionResult.Outcome
    var message: String
    var sessionID: UUID
    var sequence: Int
    var volume: Double?
    var serverTime: Double? = nil
    var transportVersion: Int? = nil
    var disposition: Disposition? = nil
    static func failure(_ message: String, request: VolumeRequest) -> Self {
        .init(outcome:.failed,message:message,sessionID:request.sessionID,sequence:request.sequence,volume:nil)
    }
}

/// Phone-side validation complements receiver-side ordering. Consume before I/O;
/// errors are never retried. One active session and no reopening closed IDs.
struct VolumeCommandGate {
    private var active: UUID?
    private var activeProfile: String?
    private var sequence = -1
    private var closed: [UUID:Double] = [:]
    private var seen: [UUID:Double] = [:]
    mutating func accept(_ request: VolumeRequest, configuration: WizardryConfiguration, now: Double) -> Bool {
        closed = closed.filter { now-$0.value < 1800 }
        seen = seen.filter { now-$0.value < 30 }
        guard configuration.allowsControl, request.isValid, now.isFinite, request.createdAt <= now+0.1,
              now-request.createdAt <= 1, request.revision == configuration.revision,
              configuration.supportsLiveVolume, request.profileID.map({$0 == configuration.selectedProfileID}) ?? true,
              seen[request.id] == nil,
              closed[request.sessionID] == nil else { return false }
        if request.operation == .begin {
            if let active { closed[active] = now }
            active = request.sessionID; activeProfile = configuration.selectedProfileID; sequence = 0
        } else {
            guard active == request.sessionID, activeProfile == configuration.selectedProfileID,
                  request.sequence > sequence else { return false }
            sequence = request.sequence
            if request.operation == .end { closed[request.sessionID] = now; active = nil }
        }
        seen[request.id] = now; return true
    }
    mutating func invalidate(now: Double) {
        if let active { closed[active] = now }
        active = nil; activeProfile = nil
    }
}

/// Readback acknowledges the actual system level, allowing small slider
/// rounding differences. An unchanged or invalid reading cannot confirm a move.
enum VolumeReadback {
    static func confirms(actual: Double, target: Double, previous: Double) -> Bool {
        guard confirms(actual:actual,target:target), previous.isFinite, (0...1).contains(previous) else { return false }
        let requestedChange = target-previous
        guard abs(requestedChange) >= 0.001 else { return true }
        let actualChange = actual-previous
        return actualChange*requestedChange > 0 && abs(actualChange) >= min(abs(requestedChange),0.0001)
    }
    static func confirms(actual: Double, target: Double) -> Bool {
        actual.isFinite && target.isFinite && (0...1).contains(actual) &&
        (0...1).contains(target) && abs(actual-target) <= 0.01
    }
}
