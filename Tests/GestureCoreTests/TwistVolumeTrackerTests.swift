import XCTest
@testable import GestureCore

final class TwistVolumeTrackerTests: XCTestCase {
    private func radians(_ degrees: Double) -> Double { degrees * .pi/180 }

    func testStartsAtActualVolumeAndSignedTwistRespondsOnFirstSample() {
        for startingVolume in [0.12,0.37,0.83] {
            for origin in [0.0,0.7,3.13,-3.13] {
                for direction in [-1.0,1.0] {
                    var tracker = TwistVolumeTracker()
                    tracker.begin(volume:startingVolume,roll:origin,time:10)
                    XCTAssertEqual(tracker.target,startingVolume)
                    XCTAssertEqual(tracker.startingVolume,startingVolume)
                    XCTAssertEqual(tracker.twistRadians,0)
                    let moved = ExtensionArbiter.offset(origin+direction*radians(9),from:0)
                    XCTAssertEqual(tracker.update(roll:moved,time:10.01),startingVolume+direction*0.05,accuracy:0.000001)
                    XCTAssertEqual(tracker.twistRadians,direction*radians(9),accuracy:0.000001)
                    XCTAssertEqual(tracker.angularVelocity,direction*radians(9)/0.01,accuracy:0.000001)
                }
            }
        }
    }

    func testNinetyDegreeTurnChangesFiftyPercentagePointsAtBothDeliveredRates() {
        for rate in [50.0,100.0] {
            for direction in [-1.0,1.0] {
                var tracker = TwistVolumeTracker()
                tracker.begin(volume:0.5,roll:0,time:0)
                var previous = tracker.target
                for i in 1...Int(rate) {
                    let fraction = Double(i)/rate
                    let actual = tracker.update(roll:direction * .pi/2 * fraction,time:fraction)
                    XCTAssertEqual(actual,0.5+direction*0.5*fraction,accuracy:0.000001)
                    XCTAssertLessThanOrEqual(abs(actual-previous),0.0100001)
                    previous = actual
                }
                XCTAssertEqual(tracker.target,direction > 0 ? 1 : 0,accuracy:0.000001)
            }
        }
    }

    func testCrossingPlusMinusPiUsesSmallSignedIncrementInBothDirections() {
        for direction in [-1.0,1.0] {
            var tracker = TwistVolumeTracker()
            tracker.begin(volume:0.5,roll:direction*radians(179),time:0)
            XCTAssertEqual(tracker.update(roll:-direction*radians(179),time:0.01),0.5+direction*2/180,accuracy:0.000001)
            XCTAssertEqual(tracker.twistRadians,direction*radians(2),accuracy:0.000001)
        }
    }

    func testBoundsHaveNoWindupAndReverseImmediately() {
        for direction in [-1.0,1.0] {
            var tracker = TwistVolumeTracker()
            tracker.begin(volume:0.5,roll:0,time:0)
            for i in 1...12 {
                _ = tracker.update(roll:direction*radians(Double(i)*10),time:Double(i)*0.01)
            }
            let bound = direction > 0 ? 1.0 : 0.0
            XCTAssertEqual(tracker.target,bound)
            XCTAssertEqual(tracker.update(roll:direction*radians(111),time:0.13),bound-direction*0.05,accuracy:0.000001)
        }
    }

    func testThirtySecondStationaryHoldPreservesTargetAndNextTurnResponds() {
        var tracker = TwistVolumeTracker()
        tracker.begin(volume:0.37,roll:1.2,time:0)
        for i in 1...3000 {
            XCTAssertEqual(tracker.update(roll:1.2,time:Double(i)/100),0.37,accuracy:0.000001)
        }
        XCTAssertEqual(tracker.angularVelocity,0)
        XCTAssertEqual(tracker.update(roll:1.2+radians(9),time:30.01),0.42,accuracy:0.000001)
    }

    func testHapticAndTapFreezesRebaseWithoutAccumulatingHiddenTwist() {
        var tracker = TwistVolumeTracker()
        tracker.begin(volume:0.4,roll:0,time:0)
        XCTAssertEqual(tracker.update(roll:radians(18),time:0.01),0.5,accuracy:0.000001)
        let twist = tracker.twistRadians
        for i in 2...20 {
            XCTAssertEqual(tracker.update(roll:radians(Double(i)*9),time:Double(i)*0.01,frozen:true),0.5,accuracy:0.000001)
        }
        XCTAssertEqual(tracker.twistRadians,twist)
        XCTAssertEqual(tracker.angularVelocity,0)
        XCTAssertEqual(tracker.update(roll:radians(-171),time:0.21),0.55,accuracy:0.000001)
        tracker.freeze(roll:0,time:0.22)
        XCTAssertEqual(tracker.update(roll:radians(-9),time:0.23),0.5,accuracy:0.000001)
    }

    func testDeliveryGapRebasesAndInvalidOrOutOfOrderSamplesClearReference() {
        var tracker = TwistVolumeTracker()
        tracker.begin(volume:0.5,roll:0,time:0)
        XCTAssertEqual(tracker.update(roll:radians(90),time:1),0.5)
        XCTAssertEqual(tracker.update(roll:radians(99),time:1.01),0.55,accuracy:0.000001)
        for invalid in [(Double.nan,1.02),(0,Double.infinity),(0,1.01),(0,1.0)] {
            tracker.begin(volume:0.5,roll:0,time:1.01)
            XCTAssertEqual(tracker.update(roll:invalid.0,time:invalid.1),0.5)
            XCTAssertEqual(tracker.angularVelocity,0)
            XCTAssertEqual(tracker.update(roll:radians(90),time:1.03),0.5)
            XCTAssertEqual(tracker.update(roll:radians(81),time:1.04),0.45,accuracy:0.000001)
        }
    }

    func testFreshBeginResetsAnchorAndInvalidInitialReadingCannotJump() {
        var tracker = TwistVolumeTracker()
        tracker.begin(volume:0.8,roll:0,time:0)
        _ = tracker.update(roll:radians(18),time:0.01)
        tracker.begin(volume:0.2,roll:radians(170),time:10)
        XCTAssertEqual(tracker.startingVolume,0.2)
        XCTAssertEqual(tracker.twistRadians,0)
        XCTAssertEqual(tracker.update(roll:radians(179),time:10.01),0.25,accuracy:0.000001)
        tracker.begin(volume:0.4,roll:.nan,time:11)
        XCTAssertEqual(tracker.update(roll:radians(90),time:11.01),0.4)
        XCTAssertEqual(tracker.update(roll:radians(99),time:11.02),0.45,accuracy:0.000001)
    }
}
