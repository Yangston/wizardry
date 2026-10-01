import CoreMotion
import Foundation

struct CapturedMotion {
    var time: Double; var roll: Double; var pitch: Double; var yaw: Double
    var attitude: MotionQuaternion
    var acceleration: MotionVector; var rotation: MotionVector; var gravity: MotionVector
}

/// All feature extraction, template matching and enrollment operate on the
/// sensor queue. UI receives immutable samples/events, never CMMotion objects.
final class MotionCapture: @unchecked Sendable {
    let queue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "Wizardry motion"; queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var rotation = MotionVector(x:0,y:0,z:0)
    private var rotationTime = -Double.infinity
    private var detector = FingerTapDetector()
    private var enrollment: TapEnrollment?
    private var enrollmentUntil: Double?
    private var enrollmentLastSample: Double?
    private var enrollmentSamples = 0
    private var enrollmentFirstSample: Double?
    var motionDelivered: ((CapturedMotion) -> Void)?
    var tapDelivered: ((FingerTapDetector.Output) -> Void)?
    var enrollmentDelivered: ((TapEnrollment, Bool) -> Void)?
    func reset(model: FingerTapModel?) {
        queue.addOperation { self.detector = FingerTapDetector(model:model); self.rotationTime = -.infinity }
    }
    func suppressHaptic(at time: Double) {
        queue.addOperation { self.detector.suppress(until:time+0.35) }
    }
    func startEnrollmentStage(_ enrollment: TapEnrollment, at time: Double) {
        queue.addOperation {
            self.enrollment = enrollment; self.enrollmentUntil = time+enrollment.stage.duration
            self.enrollmentLastSample = nil; self.enrollmentFirstSample = nil; self.enrollmentSamples = 0
            self.detector = FingerTapDetector()
        }
    }
    func cancelEnrollment() {
        queue.addOperation { self.enrollment = nil; self.enrollmentUntil = nil }
    }
    func accept(_ motion: CMDeviceMotion) {
        let a = motion.userAcceleration, r = motion.rotationRate, g = motion.gravity, q = motion.attitude.quaternion
        rotation = .init(x:r.x,y:r.y,z:r.z); rotationTime = motion.timestamp
        motionDelivered?(.init(time:motion.timestamp,roll:motion.attitude.roll,pitch:motion.attitude.pitch,yaw:motion.attitude.yaw,
                              attitude:.init(x:q.x,y:q.y,z:q.z,w:q.w),acceleration:.init(x:a.x,y:a.y,z:a.z),
                              rotation:rotation,gravity:.init(x:g.x,y:g.y,z:g.z)))
    }
    func accept(_ sample: CMAccelerometerData) {
        let now = ProcessInfo.processInfo.systemUptime
        guard sample.timestamp <= now, now-sample.timestamp <= 0.25 else {
            detector.reset()
            if let learning = enrollment {
                enrollment = nil; enrollmentUntil = nil; enrollmentDelivered?(learning,false)
            }
            return
        }
        // Stale gyro data cannot be matched against a tap template.
        guard sample.timestamp-rotationTime >= -0.03, sample.timestamp-rotationTime <= 0.1 else { return }
        let a = sample.acceleration
        let output = detector.update(raw:.init(x:a.x,y:a.y,z:a.z),rotation:rotation,time:sample.timestamp)
        tapDelivered?(output)
        if var learning = enrollment, let until = enrollmentUntil {
            if let previous = enrollmentLastSample, sample.timestamp-previous > 0.1 || sample.timestamp <= previous {
                enrollment = nil; enrollmentUntil = nil; enrollmentDelivered?(learning,false); return
            }
            enrollmentLastSample = sample.timestamp
            if enrollmentFirstSample == nil { enrollmentFirstSample = sample.timestamp }
            enrollmentSamples += 1
            if let observation = output.observation { learning.observe(observation) }
            if sample.timestamp >= until {
                let duration = sample.timestamp-(enrollmentFirstSample ?? sample.timestamp)
                let rate = Double(enrollmentSamples)/max(0.01,duration)
                // Shortened/suspended recordings must never count as a five-minute check.
                let complete = duration >= learning.stage.duration-0.1 && rate >= 70
                if complete { learning.finishStage() }
                enrollment = nil; enrollmentUntil = nil
                enrollmentDelivered?(learning,complete)
            } else { enrollment = learning }
        }
    }
}
