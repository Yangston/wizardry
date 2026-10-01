import Foundation

struct TapTemplate: Codable, Equatable {
    var features: [[Double]]
    var isValid: Bool { (10...80).contains(features.count) && features.allSatisfy {$0.count == 6 && $0.allSatisfy(\.isFinite)} }
    static func distance(_ a: Self, _ b: Self) -> Double {
        guard a.isValid, b.isValid else { return .infinity }
        var previous = [Double](repeating:.infinity,count:b.features.count+1); previous[0] = 0
        for i in 1...a.features.count {
            var row = [Double](repeating:.infinity,count:b.features.count+1)
            for j in 1...b.features.count where abs(i-j) <= 12 {
                let cost = zip(a.features[i-1],b.features[j-1]).reduce(0.0) { $0 + pow($1.0-$1.1,2) }
                row[j] = sqrt(cost) + min(previous[j],previous[j-1],row[j-1])
            }
            previous = row
        }
        return previous[b.features.count]/Double(max(a.features.count,b.features.count))
    }
}

struct FingerTapModel: Codable, Equatable {
    var positive: [TapTemplate]
    var negative: [TapTemplate]
    var threshold: Double
    var validated = false
    var isValid: Bool {
        (5...40).contains(positive.count) && (5...40).contains(negative.count) &&
        threshold.isFinite && threshold > 0 && (positive+negative).allSatisfy(\.isValid)
    }
    func score(_ sample: TapTemplate) -> Double {
        let p = positive.map {TapTemplate.distance($0,sample)}.min() ?? .infinity
        let n = negative.map {TapTemplate.distance($0,sample)}.min() ?? .infinity
        return p < n*0.85 ? p : .infinity
    }
    func recognizes(_ sample: TapTemplate) -> Bool { validated && isValid && score(sample) <= threshold }
}

/// Raw accelerometer input, high-pass features, bounded 300 ms DTW windows.
/// A tap is an input event, independent of the action assigned by its context.
struct FingerTapDetector {
    struct Event: Equatable { let time: Double; let kind = "singleFingerTap" }
    struct Observation { var time: Double; var template: TapTemplate; var recognized: Bool }
    struct Output { var event: Event?; var observation: Observation?; var frozen: Bool }
    var model: FingerTapModel?
    private var low = MotionVector(x:0,y:0,z:0)
    private var lastTime: Double?
    private var ring: [(Double,[Double])] = []
    private var candidate: Double?
    private var pending: Double?
    private var suppressedUntil = -Double.infinity
    private var refractoryUntil = -Double.infinity
    private var noise = 0.005
    init(model: FingerTapModel? = nil) { self.model = model }
    var isEvaluating: Bool { candidate != nil || pending != nil }
    mutating func reset() { let saved = model; self = Self(); model = saved }
    mutating func suppress(until time: Double) { reset(); suppressedUntil = time }
    mutating func update(raw: MotionVector, rotation: MotionVector, time: Double) -> Output {
        var output = Output(event:nil,observation:nil,frozen:false)
        guard raw.isFinite, rotation.isFinite, time.isFinite else { reset(); return output }
        if let previous = lastTime, time <= previous || time-previous > 0.25 { reset() }
        let dt = time-(lastTime ?? time-0.01)
        if lastTime == nil { low = raw }
        lastTime = time
        let alpha = dt/(0.02+dt)
        low.x += alpha*(raw.x-low.x); low.y += alpha*(raw.y-low.y); low.z += alpha*(raw.z-low.z)
        let high = MotionVector(x:raw.x-low.x,y:raw.y-low.y,z:raw.z-low.z)
        let feature = [high.x,high.y,high.z,rotation.x*0.15,rotation.y*0.15,rotation.z*0.15]
        ring.append((time,feature)); ring = ring.filter {time-$0.0 <= 0.5}
        if time < suppressedUntil { return output }
        let energy = high.length
        if candidate == nil, time >= refractoryUntil, energy > max(0.025,noise*4), ring.count >= 10 {
            candidate = time
            // A possible second impulse freezes dispatch before its DTW result.
        }
        if let peak = candidate, time-peak >= 0.2 {
            let sample = TapTemplate(features:ring.filter {$0.0 >= peak-0.1 && $0.0 <= peak+0.2}.map {$0.1})
            let recognized = model?.recognizes(sample) == true
            output.observation = .init(time:peak,template:sample,recognized:recognized)
            if recognized {
                if let first = pending, peak-first <= 0.45 { pending = nil; refractoryUntil = peak+0.45 }
                else { pending = peak }
            }
            candidate = nil
            refractoryUntil = max(refractoryUntil,peak+0.22)
        }
        if candidate == nil, let peak = pending, time-peak >= 0.45 {
            output.event = .init(time:peak); pending = nil; refractoryUntil = time+0.3
        }
        if candidate == nil, pending == nil, energy < 0.025 { noise += 0.01*(energy-noise) }
        output.frozen = isEvaluating && model?.validated == true
        return output
    }
}

/// Guided, timed recording. Validation taps have an explicit expected count,
/// so missed candidate detection cannot disappear from the recall denominator.
struct TapEnrollment {
    enum Stage: Int, CaseIterable {
        case stationary, moving, negatives, validationTaps, validationNegatives, complete
        var duration: Double {
            switch self { case .stationary,.moving,.validationTaps: return 25
            case .negatives: return 60; case .validationNegatives: return 300; case .complete: return 0 }
        }
        var instruction: String {
            switch self {
            case .stationary: return "Make exactly 20 single finger taps, about one per second, holding your arm still."
            case .moving: return "Make exactly 20 single taps while gently raising and lowering your hand."
            case .negatives: return "Do not single-tap. Extend, stop, twist, clench, shake, and double-touch your fingers."
            case .validationTaps: return "New trials: exactly 20 single taps, about one per second. Mix still and moving taps."
            case .validationNegatives: return "Five-minute check: move naturally, extend, stop, twist, clench, and double-touch. No single taps."
            case .complete: return "Enrollment finished."
            }
        }
    }
    var stage = Stage.stationary
    private(set) var positive: [TapTemplate] = []
    private(set) var negative: [TapTemplate] = []
    private var validation: [TapTemplate] = []
    private var validationNegative: [TapTemplate] = []
    private var validationNegativeTimes: [Double] = []
    private var observations: [FingerTapDetector.Observation] = []
    private(set) var model: FingerTapModel?
    private(set) var report = ""
    mutating func observe(_ observation: FingerTapDetector.Observation) {
        guard observation.template.isValid, observations.count < 2000 else { return }
        observations.append(observation)
    }
    /// Each stage is explicitly started by the user; preparation motion is excluded.
    mutating func finishStage() {
        let clips = observations.map(\.template)
        switch stage {
        case .stationary,.moving: positive.append(contentsOf:clips.prefix(20))
        case .negatives:
            // The two halves of a deliberate double touch are not negative
            // single-touch templates: temporal cancellation handles that input.
            let singles = observations.enumerated().filter { index, item in
                !observations.enumerated().contains { otherIndex, other in
                    index != otherIndex && abs(item.time-other.time) <= 0.45
                }
            }.map { $0.element.template }
            negative = Array(singles.prefix(40))
        case .validationTaps: validation = clips
        case .validationNegatives:
            validationNegative = clips; validationNegativeTimes = observations.map(\.time)
        case .complete: return
        }
        observations = []
        stage = Stage(rawValue:stage.rawValue+1) ?? .complete
        if stage == .complete { validate() }
    }
    private mutating func validate() {
        guard positive.count >= 30, negative.count >= 5, validation.count >= 19, validation.count <= 21 else {
            report = "Not enough clean examples, or tap count differs from 20. Repeat enrollment."; return
        }
        var draft = FingerTapModel(positive:Array(positive.prefix(40)),negative:negative,threshold:1)
        let scores = validation.map {draft.score($0)}.sorted()
        let threshold = scores[18] // at least 19 of the instructed 20 taps
        guard threshold.isFinite, threshold >= 0 else { report = "Taps overlap non-tap motion. Repeat enrollment."; return }
        draft.threshold = max(0.000001,threshold*1.05)
        var pending: Double?
        var falseCount = 0
        for (sample,time) in zip(validationNegative,validationNegativeTimes) where draft.score(sample) <= draft.threshold {
            if let first = pending {
                if time-first <= 0.45 { pending = nil }
                else { falseCount += 1; pending = time }
            } else { pending = time }
        }
        if pending != nil { falseCount += 1 }
        guard falseCount <= 1 else { report = "\(falseCount) false detections in five minutes. Repeat enrollment."; return }
        draft.validated = true; model = draft
        report = "Validated: at least 19/20 tap candidates; \(falseCount) false candidates / 5 min. Test end-to-end lock next."
    }
}
