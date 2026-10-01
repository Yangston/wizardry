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
    mutating func interruptMotion() { stableYaw = nil; stableSince = nil; lastTime = nil }
    mutating func update(yaw: Double, acceleration: Double, rotation: Double, time: Double) -> Route {
        guard let offset = yawOffset(yaw),
              [acceleration,rotation,time].allSatisfy(\.isFinite), acceleration >= 0, rotation >= 0 else {
            interruptMotion(); return .transition
        }
        if let previous = lastTime {
            if time <= previous { stableYaw = nil; stableSince = nil; return .transition }
            if time-previous > 0.25 { stableYaw = nil; stableSince = nil }
        }
        lastTime = time
        relativeYaw = offset
        // Shakes near the viewing pose retain their existing discrete recognizer.
        if angle < 25 * .pi/180, rotation < 0.8, acceleration >= 0.1 { return .legacy }
        guard acceleration < 0.1, rotation < 0.2 else {
            stableSince = nil; stableYaw = nil; return .transition
        }
        if stableYaw.map({abs(Self.offset(yaw,from:$0)) > 3 * .pi/180}) ?? true {
            stableYaw = yaw; stableSince = time
        }
        guard time - (stableSince ?? time) >= 0.25 else { return .transition }
        return (70 * .pi/180...110 * .pi/180).contains(angle) ? .enterVolume : .legacy
    }
}

/// Short, from-rest strokes only: apparent rest is a heuristic, not a measured
/// position reference. Pauses reset velocity without moving the volume anchor.
struct VerticalVolumeTracker {
    private(set) var target = 0.0
    private(set) var startingVolume = 0.0
    private(set) var controlTravel = 0.0
    private(set) var controlAcceleration = 0.0
    private(set) var velocity = 0.0
    private var lastTime: Double?
    private var stillSince: Double?
    private var bias = 0.0
    private var filtered = 0.0
    private var pendingDistance = 0.0
    private(set) var lastMovement = 0.0
    mutating func begin(volume: Double, acceleration: MotionVector, gravity: MotionVector, time: Double) {
        self = Self(); target = min(1,max(0,volume)); startingVolume = target; lastTime = time; lastMovement = time
        bias = Self.vertical(acceleration,gravity)
    }
    static func vertical(_ acceleration: MotionVector, _ gravity: MotionVector) -> Double {
        guard gravity.length > 0.5 else { return 0 }
        return -acceleration.dot(gravity)/gravity.length * 9.80665
    }
    mutating func freeze(at time: Double) {
        lastTime = time; velocity = 0; filtered = 0; controlAcceleration = 0; pendingDistance = 0; stillSince = nil
    }
    mutating func update(acceleration: MotionVector, gravity: MotionVector, rotation: Double, time: Double, frozen: Bool = false) -> Double {
        guard acceleration.isFinite, gravity.isFinite, gravity.length > 0.5,
              rotation.isFinite, time.isFinite, let previous = lastTime,
              time > previous, time-previous <= 0.25 else { freeze(at:time); return target }
        let dt = time-previous; lastTime = time
        if frozen { freeze(at:time); return target }
        let apparentRest = acceleration.length < 0.035 && rotation < 0.2
        if apparentRest {
            if stillSince == nil { stillSince = time }
            if time-(stillSince ?? time) >= 0.3 {
                velocity = 0; filtered = 0; controlAcceleration = 0; pendingDistance = 0
                bias += 0.02*(Self.vertical(acceleration,gravity)-bias)
                return target
            }
        } else { stillSince = nil; lastMovement = time }
        let raw = Self.vertical(acceleration,gravity)-bias
        controlAcceleration = -raw
        filtered += dt/(0.02+dt)*(raw-filtered)
        let value = abs(filtered) < 0.12 ? 0 : filtered
        let oldVelocity = velocity
        velocity = min(1.5,max(-1.5,velocity+value*dt))
        pendingDistance += (oldVelocity+velocity)*0.5*dt
        // Flip the previous mapping to match the user's observed raise/lower
        // direction. Travel is signed in the volume-control direction, not a
        // measured absolute world height. 1 metre = 100 percentage points.
        if abs(pendingDistance) >= 0.001 {
            let change = -pendingDistance
            controlTravel += change
            target = min(1,max(0,target+change)); pendingDistance = 0
        }
        return target
    }
    var feedback: VolumeMotionFeedback {
        .init(startingVolume:startingVolume,travel:controlTravel,velocity:-velocity,acceleration:controlAcceleration)
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
    var isValid: Bool {
        createdAt.isFinite && sequence >= 0 && !revision.isEmpty &&
        (operation == .begin ? sequence == 0 && target == nil : sequence > 0 &&
         (target.map({$0.isFinite && (0...1).contains($0)}) ?? false))
    }
}

struct VolumeReply: Codable {
    var outcome: ActionResult.Outcome
    var message: String
    var sessionID: UUID
    var sequence: Int
    var volume: Double?
    var serverTime: Double? = nil
    static func failure(_ message: String, request: VolumeRequest) -> Self {
        .init(outcome:.failed,message:message,sessionID:request.sessionID,sequence:request.sequence,volume:nil)
    }
}

/// Phone-side validation complements receiver-side ordering. Consume before I/O;
/// errors are never retried. One active session and no reopening closed IDs.
struct VolumeCommandGate {
    private var active: UUID?
    private var sequence = -1
    private var closed: [UUID:Double] = [:]
    private var seen: [UUID:Double] = [:]
    mutating func accept(_ request: VolumeRequest, configuration: WizardryConfiguration, now: Double) -> Bool {
        closed = closed.filter { now-$0.value < 1800 }
        seen = seen.filter { now-$0.value < 30 }
        guard request.isValid, now.isFinite, request.createdAt <= now+0.1,
              now-request.createdAt <= 1, request.revision == configuration.revision,
              configuration.selectedProfileID == "computer", seen[request.id] == nil,
              closed[request.sessionID] == nil else { return false }
        if request.operation == .begin {
            if let active { closed[active] = now }
            active = request.sessionID; sequence = 0
        } else {
            guard active == request.sessionID, request.sequence > sequence else { return false }
            sequence = request.sequence
            if request.operation == .end { closed[request.sessionID] = now; active = nil }
        }
        seen[request.id] = now; return true
    }
}
