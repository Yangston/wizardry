import XCTest
@testable import GestureCore

final class RotationDetectorTests: XCTestCase {
    func testSustainedRotationFiresOnlyOnceUntilNeutral() {
        var detector = RotationDetector()
        var events: [RotationDetector.Gesture] = []
        for i in 0..<150 {
            let roll = i < 10 ? 0.0 : 0.8
            if let g = detector.update(roll: roll, time: Double(i) * 0.02) { events.append(g) }
        }
        XCTAssertEqual(events, [.positive])
        for i in 150..<170 { _ = detector.update(roll: 0, time: Double(i) * 0.02) }
        for i in 170..<190 {
            if let g = detector.update(roll: -0.8, time: Double(i) * 0.02) { events.append(g) }
        }
        XCTAssertEqual(events, [.positive, .negative])
    }

    func testBriefSpikeAndSmallMovementsDoNotFire() {
        var detector = RotationDetector()
        for i in 0..<100 {
            let roll = i == 20 ? 1.0 : 0.1 * sin(Double(i))
            XCTAssertNil(detector.update(roll: roll, time: Double(i) * 0.02))
        }
    }

    func testAngleWrapIsNotAGestureAndSensorGapRecalibrates() {
        var detector = RotationDetector()
        _ = detector.update(roll: 3.1, time: 0)
        XCTAssertNil(detector.update(roll: -3.1, time: 0.02))
        XCTAssertLessThan(abs(detector.relativeRoll), 0.1)
        XCTAssertNil(detector.update(roll: 1.0, time: 2))
        XCTAssertEqual(detector.relativeRoll, 0)
    }
}
