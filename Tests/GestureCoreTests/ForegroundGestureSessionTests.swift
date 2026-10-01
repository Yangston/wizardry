import XCTest
@testable import GestureCore

final class ForegroundGestureSessionTests: XCTestCase {
    private func armedSession(requireWake: Bool = true) -> ForegroundGestureSession {
        var session = ForegroundGestureSession()
        session.engine.requireWake = requireWake
        session.engine.armSeconds = 4
        session.transition(to:.active,at:1)
        session.calibrateAndArm(roll:0.4,pitch:-0.2,sampleTime:1,readyTime:1)
        return session
    }

    private func sample(_ session: inout ForegroundGestureSession, at time: Double,
                        roll: Double = 0.4, acceleration: Double = 0,
                        deliveredAt: Double? = nil) -> (accepted: Bool, event: GestureEngine.Event?) {
        session.update(roll:roll,pitch:-0.2,acceleration:acceleration,
                       sampleTime:time,now:deliveredAt ?? time)
    }

    func testRollContinuesAcrossInactiveAndActiveWithoutRestartingArm() {
        var session = armedSession()
        XCTAssertNil(sample(&session,at:1.02,roll:1.2).event)
        XCTAssertTrue(session.transition(to:.inactive,at:1.03))
        var events: [GestureEngine.Event] = []
        for i in 2...14 {
            let result = sample(&session,at:1 + Double(i)*0.02,roll:1.2)
            XCTAssertTrue(result.accepted)
            if let event = result.event { events.append(event) }
        }
        XCTAssertEqual(events,[.action(.rollPositive)])
        XCTAssertTrue(session.transition(to:.active,at:1.3))
        XCTAssertEqual(session.engine.armedUntil,5)
        XCTAssertEqual(session.engine.relativeRoll,0.8,accuracy:0.0001)
    }

    func testRepeatedSceneNotificationsNeverExtendDeadline() {
        var session = armedSession()
        for time in [1.1,1.2,2,3,4.9] {
            XCTAssertTrue(session.transition(to:.inactive,at:time))
            XCTAssertTrue(session.transition(to:.active,at:time))
            XCTAssertEqual(session.engine.armedUntil,5)
        }
        XCTAssertFalse(session.transition(to:.inactive,at:5))
        XCTAssertFalse(session.engine.isArmed(at:5))
    }

    func testBackgroundDisarmsAndReturningDoesNotRestoreTheWindow() {
        var session = armedSession()
        XCTAssertTrue(session.transition(to:.inactive,at:1.1))
        XCTAssertFalse(session.transition(to:.background,at:1.2))
        XCTAssertFalse(sample(&session,at:1.22,roll:1.2).accepted)
        XCTAssertTrue(session.transition(to:.active,at:1.3))
        XCTAssertFalse(session.engine.isArmed(at:1.3))
        XCTAssertNil(sample(&session,at:1.32,roll:1.2).event)
    }

    func testExpiryWithoutSamplesDisablesInactiveMotionEvenWithWakeDisabled() {
        for requireWake in [true,false] {
            var session = armedSession(requireWake:requireWake)
            session.transition(to:.inactive,at:1.1)
            session.expireArm(at:5)
            XCTAssertFalse(session.allowsMotion(at:5))
            XCTAssertFalse(session.engine.isArmed(at:5))
            XCTAssertFalse(sample(&session,at:5.02,roll:1.2).accepted)
        }
    }

    func testDeliveryAfterDeadlineCannotCompleteAnEarlierGesture() {
        for phase in [ForegroundGestureSession.Phase.active,.inactive] {
            var session = armedSession()
            session.transition(to:phase,at:1.01)
            // Fresh continuous samples right up to the arm deadline.
            for i in 1...191 { _ = sample(&session,at:1 + Double(i)*0.02) }
            XCTAssertNil(sample(&session,at:4.84,roll:1.2).event)
            XCTAssertNil(sample(&session,at:4.98,roll:1.2,deliveredAt:5.01).event)
            XCTAssertFalse(session.engine.isArmed(at:5.01))
        }
    }

    func testUnarmedInactiveSessionCannotWakeOrUseWakeDisabledToAct() {
        for requireWake in [true,false] {
            var session = ForegroundGestureSession()
            session.engine.requireWake = requireWake
            session.transition(to:.active,at:1)
            XCTAssertFalse(session.transition(to:.inactive,at:1.1))
            for i in 0...30 {
                let result = sample(&session,at:1.2 + Double(i)*0.02,
                                    roll:i.isMultiple(of:2) ? 1 : -1,acceleration:1.5)
                XCTAssertFalse(result.accepted)
                XCTAssertNil(result.event)
            }
        }
    }

    func testStaleFutureDuplicateAndOutOfOrderSamplesAreRejected() {
        for (sampleTime,now) in [(1.04,1.5),(1.04,1.03),(1.02,1.03),(1.01,1.03)] {
            var session = armedSession()
            _ = sample(&session,at:1.02,roll:1.2)
            let result = sample(&session,at:sampleTime,roll:1.2,deliveredAt:now)
            XCTAssertFalse(result.accepted)
            XCTAssertNil(result.event)
            XCTAssertEqual(session.engine.armedUntil,5)
        }
    }

    func testGapPreservesBaselineAndDeadlineButRequiresNeutralBeforeNextAction() {
        var session = armedSession()
        session.transition(to:.inactive,at:1.1)
        // No callbacks since calibration. The first returned pose must not act
        // or become a new neutral position just because the sensors were silent.
        for i in 0...10 {
            XCTAssertNil(sample(&session,at:1.5 + Double(i)*0.02,roll:1.2).event)
        }
        XCTAssertEqual(session.engine.armedUntil,5)
        XCTAssertEqual(session.engine.relativeRoll,0.8,accuracy:0.0001)
        for i in 0...16 { XCTAssertNil(sample(&session,at:1.72 + Double(i)*0.02).event) }
        var events: [GestureEngine.Event] = []
        for i in 0...12 {
            if let event = sample(&session,at:2.06 + Double(i)*0.02,roll:1.2).event { events.append(event) }
        }
        XCTAssertEqual(events,[.action(.rollPositive)])
        XCTAssertEqual(session.engine.armedUntil,5)
    }

    func testRejectedSampleCannotJoinTwoHalvesOfAShake() {
        var session = armedSession()
        session.transition(to:.inactive,at:1.01)
        XCTAssertNil(sample(&session,at:1.02,acceleration:1.5).event)
        XCTAssertFalse(sample(&session,at:1.04,deliveredAt:1.5).accepted)
        XCTAssertNil(sample(&session,at:1.52,acceleration:1.5).event)
        for i in 0...15 { XCTAssertNil(sample(&session,at:1.54 + Double(i)*0.02).event) }
        XCTAssertNil(sample(&session,at:1.86,acceleration:1.5).event)
        XCTAssertNil(sample(&session,at:2.06).event)
        XCTAssertEqual(sample(&session,at:2.08,acceleration:1.5).event,.action(.shake))
    }

    func testInvalidMotionAndExplicitResetDisarm() {
        var session = armedSession()
        session.transition(to:.inactive,at:1.01)
        XCTAssertFalse(sample(&session,at:1.02,roll:.nan).accepted)
        XCTAssertFalse(session.allowsMotion(at:1.02))
        session = armedSession()
        session.reset() // Stop, changed settings, navigation away, or sensor error.
        session.transition(to:.inactive,at:1.1)
        XCTAssertFalse(session.allowsMotion(at:1.1))
    }

    func testInterruptionDoesNotEraseActionCooldown() {
        var session = armedSession()
        var events: [GestureEngine.Event] = []
        for i in 1...10 {
            if let event = sample(&session,at:1 + Double(i)*0.02,roll:1.2).event { events.append(event) }
        }
        XCTAssertEqual(events,[.action(.rollPositive)])
        session.transition(to:.inactive,at:1.21)
        // After a delivery gap, neutral is held long enough to settle but the
        // 800 ms cooldown from the first action has not yet elapsed.
        for i in 0...14 { XCTAssertNil(sample(&session,at:1.5 + Double(i)*0.02).event) }
        for i in 0...7 { XCTAssertNil(sample(&session,at:1.8 + Double(i)*0.02,roll:1.2).event) }
        XCTAssertEqual(session.engine.armedUntil,5)
    }
}
