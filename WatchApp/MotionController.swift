import Combine
import CoreMotion
import Foundation
import WatchKit

@MainActor
final class MotionController: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "Hold still, then Start"
    @Published private(set) var rollDegrees = 0.0
    @Published private(set) var acceleration = "—"
    @Published private(set) var rotation = "—"
    @Published private(set) var sampleRate = 0.0
    @Published private(set) var count = 0
    @Published private(set) var lastGesture = "None yet"
    var onGesture: ((RotationDetector.Gesture) -> Void)?

    private let manager = CMMotionManager()
    private var detector = RotationDetector()
    private var generation = 0
    private var lastDisplay = 0.0
    private var firstSample: Double?
    private var samples = 0

    func start() {
        guard !running else { return }
        guard manager.isDeviceMotionAvailable else {
            status = "Motion unavailable. Test on a real watch."
            return
        }
        detector.reset()
        firstSample = nil
        samples = 0
        lastDisplay = 0
        sampleRate = 0
        generation += 1
        let session = generation
        running = true
        status = "Rotate, then return to start"
        manager.deviceMotionUpdateInterval = 1.0 / 50.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            // OperationQueue.main guarantees main-thread delivery; publishing happens in a main-actor task.
            guard let motion else {
                let message = error?.localizedDescription ?? "Motion data unavailable"
                Task { @MainActor [weak self] in
                    guard let self, self.generation == session else { return }
                    self.stop(message)
                }
                return
            }
            let timestamp = motion.timestamp
            let roll = motion.attitude.roll
            let a = motion.userAcceleration
            let r = motion.rotationRate
            Task { @MainActor [weak self] in
                guard let self, self.running, self.generation == session else { return }
                self.consume(time: timestamp, roll: roll, ax: a.x, ay: a.y, az: a.z,
                             rx: r.x, ry: r.y, rz: r.z)
            }
        }
    }

    func stop(_ message: String = "Stopped") {
        generation += 1
        manager.stopDeviceMotionUpdates()
        running = false
        detector.reset()
        status = message
    }

    func testHaptic() { WKInterfaceDevice.current().play(.click) }

    private func consume(time: Double, roll: Double, ax: Double, ay: Double, az: Double,
                         rx: Double, ry: Double, rz: Double) {
        if firstSample == nil { firstSample = time }
        samples += 1
        if let gesture = detector.update(roll: roll, time: time) {
            count += 1
            lastGesture = gesture.rawValue
            WKInterfaceDevice.current().play(.click)
            onGesture?(gesture)
        }
        if time - lastDisplay >= 0.1 {
            rollDegrees = detector.relativeRoll * 180 / .pi
            acceleration = String(format: "%.2f  %.2f  %.2f", ax, ay, az)
            rotation = String(format: "%.2f  %.2f  %.2f", rx, ry, rz)
            let elapsed = time - (firstSample ?? time)
            sampleRate = elapsed > 0 ? Double(samples - 1) / elapsed : 0
            lastDisplay = time
        }
    }
}
