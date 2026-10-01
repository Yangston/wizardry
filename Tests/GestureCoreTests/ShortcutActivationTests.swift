import XCTest
@testable import GestureCore

final class ShortcutActivationTests: XCTestCase {
    private func sample(_ activation: inout ShortcutActivation, at time: Double,
                        acceleration: Double = 0, rotation: Double = 0,
                        roll: Double = 1.2, pitch: Double = -0.4) -> ShortcutActivation.Event? {
        activation.update(roll:roll,pitch:pitch,acceleration:acceleration,
                          rotationRate:rotation,sampleTime:time,now:time + 0.001)
    }

    func testColdLaunchWaitsForForegroundAndEmitsReadyExactlyOnce() {
        var activation = ShortcutActivation()
        activation.request(at:0)
        activation.leaveForeground()
        XCTAssertEqual(activation.state,.waitingForForeground)
        XCTAssertNil(sample(&activation,at:0.5))
        XCTAssertTrue(activation.beginCapture(at:1))
        var events: [ShortcutActivation.Event] = []
        for i in 0...50 {
            if let event = sample(&activation,at:1 + Double(i)*0.02) { events.append(event) }
            if i < 13 { XCTAssertEqual(activation.state,.calibrating) }
        }
        XCTAssertEqual(events,[.ready])
        XCTAssertFalse(activation.isPending)
        XCTAssertFalse(activation.expire(at:20))
    }

    func testForegroundLaunchAndRepeatedRequestRestartCalibration() {
        var activation = ShortcutActivation()
        activation.request(at:2)
        XCTAssertTrue(activation.beginCapture(at:2))
        for i in 0...10 { XCTAssertNil(sample(&activation,at:2 + Double(i)*0.02)) }
        // A duplicate scene notification must not restart capture.
        XCTAssertFalse(activation.beginCapture(at:2.2))
        activation.request(at:2.21)
        XCTAssertTrue(activation.beginCapture(at:2.21))
        for i in 0...12 { XCTAssertNil(sample(&activation,at:2.22 + Double(i)*0.02)) }
        XCTAssertEqual(sample(&activation,at:2.48),.ready)
        XCTAssertNil(sample(&activation,at:2.5))
    }

    func testAccelerationOrRotationInterruptsStableWindow() {
        for rotationalMovement in [false,true] {
            var activation = ShortcutActivation()
            activation.request(at:0)
            activation.beginCapture(at:0)
            for i in 0...10 { XCTAssertNil(sample(&activation,at:Double(i)*0.02)) }
            XCTAssertNil(sample(&activation,at:0.22,
                                acceleration:rotationalMovement ? 0 : 0.2,
                                rotation:rotationalMovement ? 0.3 : 0))
            for i in 12...24 { XCTAssertNil(sample(&activation,at:Double(i)*0.02)) }
            XCTAssertEqual(sample(&activation,at:0.5),.ready)
        }
    }

    func testStaleSamplesGapsAndRepeatedTimestampsCannotEstablishReadiness() {
        var activation = ShortcutActivation()
        activation.request(at:0)
        activation.beginCapture(at:1)
        XCTAssertNil(sample(&activation,at:0.9)) // Queued before this capture.
        XCTAssertNil(sample(&activation,at:1))
        XCTAssertNil(sample(&activation,at:1.1))
        XCTAssertNil(sample(&activation,at:1.1)) // Duplicate resets stability.
        XCTAssertNil(sample(&activation,at:1.2))
        XCTAssertNil(sample(&activation,at:1.3))
        XCTAssertNil(sample(&activation,at:1.6)) // Missing samples reset stability.
        XCTAssertNil(activation.update(roll:0,pitch:0,acceleration:0,rotationRate:0,
                                       sampleTime:1.7,now:2)) // Delayed delivery.
        for i in 0...12 { XCTAssertNil(sample(&activation,at:2 + Double(i)*0.02)) }
        XCTAssertEqual(sample(&activation,at:2.26),.ready)
    }

    func testTenSecondTimeoutIncludesForegroundWaitAndCalibration() {
        var waiting = ShortcutActivation()
        waiting.request(at:3)
        XCTAssertFalse(waiting.expire(at:12.99))
        XCTAssertTrue(waiting.expire(at:13))
        XCTAssertFalse(waiting.beginCapture(at:13.1))
        XCTAssertFalse(waiting.isPending)

        var calibrating = ShortcutActivation()
        calibrating.request(at:3)
        XCTAssertTrue(calibrating.beginCapture(at:12.8))
        XCTAssertNil(sample(&calibrating,at:12.8))
        XCTAssertNil(sample(&calibrating,at:12.9))
        XCTAssertEqual(sample(&calibrating,at:13),.timedOut)
        XCTAssertNil(sample(&calibrating,at:13.02))
    }

    func testCancelledRequestCannotReplayOnAnOrdinaryWristRaise() {
        for beganCapture in [false,true] {
            var activation = ShortcutActivation()
            activation.request(at:0)
            if beganCapture { activation.beginCapture(at:0) }
            activation.cancel() // Stop, changed settings, or a sensor error.
            XCTAssertFalse(activation.beginCapture(at:1))
            for i in 0...30 { XCTAssertNil(sample(&activation,at:1 + Double(i)*0.02)) }
        }
        var activation = ShortcutActivation()
        activation.request(at:0)
        activation.beginCapture(at:0)
        XCTAssertNil(sample(&activation,at:0))
        activation.leaveForeground()
        XCTAssertFalse(activation.isPending)
        XCTAssertFalse(activation.beginCapture(at:1))
        XCTAssertNil(sample(&activation,at:1.3))
    }

    func testInvalidMotionCancelsRatherThanEmittingReady() {
        var activation = ShortcutActivation()
        activation.request(at:0)
        activation.beginCapture(at:0)
        XCTAssertEqual(sample(&activation,at:0,rotation:.nan),.invalidMotion)
        XCTAssertFalse(activation.isPending)
        XCTAssertNil(sample(&activation,at:0.3))
    }

    func testCalibratedBaselineAllowsFirstGestureAndStartsFullArmedWindow() {
        for requireWake in [true,false] {
            var activation = ShortcutActivation()
            var engine = GestureEngine()
            engine.requireWake = requireWake
            engine.armSeconds = 4
            activation.request(at:0)
            activation.beginCapture(at:1)
            // Deliberate launch shakes/twists cannot produce a ready event.
            for i in 0...20 {
                XCTAssertNil(sample(&activation,at:1 + Double(i)*0.02,
                                    acceleration:1.5,rotation:2,roll:i.isMultiple(of:2) ? 1 : -1))
            }
            for i in 21...33 { XCTAssertNil(sample(&activation,at:1 + Double(i)*0.02)) }
            let readyTime = 1.68
            XCTAssertEqual(sample(&activation,at:readyTime),.ready)
            let deliveredAt = readyTime + 0.01
            engine.calibrateAndArm(roll:1.2,pitch:-0.4,sampleTime:readyTime,readyTime:deliveredAt)
            XCTAssertTrue(engine.isArmed)
            XCTAssertEqual(engine.armedUntil,deliveredAt + 4,accuracy:0.0001)
            XCTAssertEqual(engine.relativeRoll,0)
            var events: [GestureEngine.Event] = []
            for i in 1...20 {
                if let event = engine.update(roll:2.1,pitch:-0.4,acceleration:0,
                                             time:readyTime + Double(i)*0.02) { events.append(event) }
            }
            XCTAssertEqual(events,[.action(.rollPositive)])
            // Wrist-down reset still disarms the calibrated engine.
            engine.reset()
            XCTAssertFalse(engine.isArmed)
        }
    }
}
