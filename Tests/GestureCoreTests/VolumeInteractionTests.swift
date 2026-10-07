import XCTest
@testable import GestureCore

final class VolumeInteractionTests: XCTestCase {
    private let zero = MotionVector(x:0,y:0,z:0)
    private let gravity = MotionVector(x:0,y:0,z:-1)
    private func pose(_ radians: Double) -> MotionQuaternion {
        .init(x:sin(radians/2),y:0,z:0,w:cos(radians/2))
    }
    func testYawEntryRequiresSettlingFromAnyHeadingOnEitherWrist() {
        for origin in [0.0,0.7,3.13,-3.13] {
            for sign in [-1.0,1.0] {
                var arbiter = ExtensionArbiter(); arbiter.calibrate(yaw:origin)
                let extended = ExtensionArbiter.offset(origin + sign * .pi/2,from:0)
                XCTAssertEqual(arbiter.update(yaw:extended,acceleration:0,rotation:1,time:0),.transition)
                for time in [0.1,0.2,0.3] {
                    XCTAssertEqual(arbiter.update(yaw:extended,acceleration:0,rotation:0,time:time),.transition)
                }
                XCTAssertEqual(arbiter.update(yaw:extended,acceleration:0,rotation:0,time:0.36),.enterVolume)
                XCTAssertEqual(arbiter.relativeYaw,sign * .pi/2,accuracy:0.00001)
                XCTAssertTrue(arbiter.isViewing(yaw:origin+0.1))
                XCTAssertFalse(arbiter.isViewing(yaw:extended))
            }
        }
    }
    func testPureZRotationEntersWithoutChangingWatchFaceNormal() {
        let initial = MotionQuaternion(x:0,y:0,z:0,w:1)
        let turned = MotionQuaternion(x:0,y:0,z:sin(.pi/4),w:cos(.pi/4))
        XCTAssertEqual(initial.normal,turned.normal) // regression: old detector missed this
        var arbiter = ExtensionArbiter(); arbiter.calibrate(yaw:0)
        for time in [0.0,0.1,0.2] { XCTAssertEqual(arbiter.update(yaw:.pi/2,acceleration:0,rotation:0,time:time),.transition) }
        XCTAssertEqual(arbiter.update(yaw:.pi/2,acceleration:0,rotation:0,time:0.26),.enterVolume)
        XCTAssertFalse(arbiter.isViewing(yaw:.pi/2)) // must not immediately stop volume
        XCTAssertTrue(arbiter.isViewing(yaw:0))
    }
    func testTiltWithoutYawCannotEnterAndLegacyGesturesRemainAvailable() {
        XCTAssertNotEqual(pose(0).normal,pose(.pi/2).normal)
        var arbiter = ExtensionArbiter(); arbiter.calibrate(yaw:0)
        XCTAssertEqual(arbiter.update(yaw:0,acceleration:1.5,rotation:0,time:0),.legacy)
        for time in [0.1,0.2,0.3] { _ = arbiter.update(yaw:0,acceleration:0,rotation:0,time:time) }
        XCTAssertEqual(arbiter.update(yaw:0,acceleration:0,rotation:0,time:0.4),.legacy)
        var engine = GestureEngine()
        engine.calibrateAndArm(roll:0,pitch:0,sampleTime:0,readyTime:0)
        for i in 1...50 { XCTAssertNil(engine.update(roll:0.9,pitch:0,acceleration:0,time:Double(i)*0.01,suppressActions:true)) }
        var events: [GestureEngine.Event] = []
        for i in 51...75 {
            if let event = engine.update(roll:0.9,pitch:0,acceleration:0,time:Double(i)*0.01) { events.append(event) }
        }
        XCTAssertEqual(events,[.action(.rollPositive)])
        _ = engine.update(roll:0.9,pitch:0,acceleration:0,time:0.76,suppressActions:true)
        for i in 77...100 { XCTAssertNil(engine.update(roll:0.9,pitch:0,acceleration:0,time:Double(i)*0.01)) }
    }
    func testYawWrapAndInvalidReference() {
        var arbiter = ExtensionArbiter(); arbiter.calibrate(yaw:3.13)
        XCTAssertTrue(arbiter.isViewing(yaw:-3.13))
        XCTAssertEqual(arbiter.yawOffset(-3.13) ?? 1,0.0231853,accuracy:0.00001)
        arbiter.calibrate(yaw:.nan)
        XCTAssertNil(arbiter.yawOffset(0))
        XCTAssertEqual(arbiter.update(yaw:.pi/2,acceleration:0,rotation:0,time:0),.transition)
    }
    func testGapDuplicateAndInvalidSamplesRequireFreshSettling() {
        var arbiter = ExtensionArbiter(); arbiter.calibrate(yaw:0)
        _ = arbiter.update(yaw:.pi/2,acceleration:0,rotation:0,time:0)
        XCTAssertEqual(arbiter.update(yaw:.pi/2,acceleration:0,rotation:0,time:1),.transition)
        XCTAssertEqual(arbiter.update(yaw:.pi/2,acceleration:0,rotation:0,time:1),.transition)
        XCTAssertEqual(arbiter.update(yaw:.nan,acceleration:0,rotation:0,time:1.1),.transition)
        for time in [1.2,1.3,1.4] { XCTAssertEqual(arbiter.update(yaw:.pi/2,acceleration:0,rotation:0,time:time),.transition) }
        XCTAssertEqual(arbiter.update(yaw:.pi/2,acceleration:0,rotation:0,time:1.46),.enterVolume)
    }
    func testVerticalProjectionReversalsPauseAndBounds() {
        XCTAssertEqual(VerticalVolumeTracker.vertical(.init(x:0,y:0,z:0.1),gravity),0.980665,accuracy:0.00001)
        XCTAssertEqual(VerticalVolumeTracker.vertical(.init(x:0.1,y:0,z:0),gravity),0,accuracy:0.00001)
        var tracker = VerticalVolumeTracker()
        tracker.begin(volume:0.5,acceleration:zero,gravity:gravity,time:0)
        for i in 1...20 { _ = tracker.update(acceleration:.init(x:0,y:0,z:0.1),gravity:gravity,rotation:0,time:Double(i)*0.01) }
        XCTAssertLessThan(tracker.target,0.5) // opposite of the previous mapping
        for i in 21...100 { _ = tracker.update(acceleration:zero,gravity:gravity,rotation:0,time:Double(i)*0.01) }
        XCTAssertEqual(tracker.velocity,0)
        let held = tracker.target
        for i in 101...600 { _ = tracker.update(acceleration:zero,gravity:gravity,rotation:0,time:Double(i)*0.01) }
        XCTAssertEqual(tracker.target,held)
        for i in 601...620 { _ = tracker.update(acceleration:.init(x:0,y:0,z:-0.1),gravity:gravity,rotation:0,time:Double(i)*0.01) }
        XCTAssertGreaterThan(tracker.target,held)
        for i in 621...900 { _ = tracker.update(acceleration:.init(x:0,y:0,z:-1),gravity:gravity,rotation:0,time:Double(i)*0.01) }
        XCTAssertEqual(tracker.target,1)
        tracker.begin(volume:0.12,acceleration:zero,gravity:gravity,time:10)
        for i in 1...300 { _ = tracker.update(acceleration:.init(x:0,y:0,z:1),gravity:gravity,rotation:0,time:10+Double(i)*0.01) }
        XCTAssertEqual(tracker.target,0)
    }
    func testFlippedStrokesAnchorToCurrentVolumeAndChangeGraduallyAtDeliveredRates() {
        for rate in [50.0,100.0] {
            for initial in [0.12,0.37,0.83] {
                for direction in [-1.0,1.0] {
                    var tracker = VerticalVolumeTracker()
                    tracker.begin(volume:initial,acceleration:zero,gravity:gravity,time:0)
                    XCTAssertEqual(tracker.target,initial)
                    XCTAssertEqual(tracker.feedback.startingVolume,initial)
                    XCTAssertEqual(tracker.feedback.travel,0)
                    var previous = initial
                    for i in 1...Int(rate*0.2) {
                        let value = tracker.update(acceleration:.init(x:0,y:0,z:direction*0.1),gravity:gravity,
                                                   rotation:0,time:Double(i)/rate)
                        // A stroke changes the current level incrementally; it
                        // never jumps to an absolute height-derived percentage.
                        XCTAssertLessThan(abs(value-previous),0.01)
                        if direction < 0 { XCTAssertGreaterThanOrEqual(value,previous) }
                        else { XCTAssertLessThanOrEqual(value,previous) }
                        previous = value
                    }
                    if direction < 0 {
                        XCTAssertGreaterThan(tracker.target,initial)
                        XCTAssertGreaterThan(tracker.feedback.travel,0)
                        XCTAssertGreaterThan(tracker.feedback.velocity,0)
                    } else {
                        XCTAssertLessThan(tracker.target,initial)
                        XCTAssertLessThan(tracker.feedback.travel,0)
                        XCTAssertLessThan(tracker.feedback.velocity,0)
                    }
                    let held = tracker.target, travel = tracker.feedback.travel
                    tracker.freeze(at:0.3)
                    XCTAssertEqual(tracker.target,held)
                    XCTAssertEqual(tracker.feedback.travel,travel)
                    XCTAssertEqual(tracker.feedback.velocity,0)
                }
            }
        }
    }
    func testTapFreezeAndDeliveryGapNeverIntegrateImpulse() {
        var tracker = VerticalVolumeTracker()
        tracker.begin(volume:0.3,acceleration:zero,gravity:gravity,time:0)
        _ = tracker.update(acceleration:.init(x:0,y:0,z:2),gravity:gravity,rotation:0,time:0.01,frozen:true)
        XCTAssertEqual(tracker.target,0.3)
        _ = tracker.update(acceleration:.init(x:0,y:0,z:2),gravity:gravity,rotation:0,time:1)
        XCTAssertEqual(tracker.target,0.3)
        XCTAssertEqual(tracker.velocity,0)
    }
    func testVolumeGateRejectsOldRevisionExpiryOrderingAndClosedSessions() {
        let configuration = WizardryConfiguration()
        var gate = VolumeCommandGate()
        var request = VolumeRequest(sessionID:UUID(),revision:configuration.revision,sequence:0,createdAt:100,operation:.begin)
        XCTAssertTrue(gate.accept(request,configuration:configuration,now:100))
        XCTAssertFalse(gate.accept(request,configuration:configuration,now:100))
        request.id = UUID(); request.sequence = 2; request.operation = .update; request.target = 0.6
        XCTAssertTrue(gate.accept(request,configuration:configuration,now:100.2))
        request.id = UUID(); request.sequence = 1
        XCTAssertFalse(gate.accept(request,configuration:configuration,now:100.3))
        request.sequence = 3; request.operation = .end
        XCTAssertTrue(gate.accept(request,configuration:configuration,now:100.3))
        request.id = UUID(); request.sequence = 4; request.operation = .update
        XCTAssertFalse(gate.accept(request,configuration:configuration,now:100.4))
        request = VolumeRequest(sessionID:UUID(),revision:"old",sequence:0,createdAt:100,operation:.begin)
        XCTAssertFalse(gate.accept(request,configuration:configuration,now:100.5))
        request.revision = configuration.revision
        XCTAssertFalse(gate.accept(request,configuration:configuration,now:101.1))
        XCTAssertFalse(gate.accept(request,configuration:configuration,now:99.8))
    }
    func testOldWakeConfigurationDecodesButNeverEnablesAutomaticActions() throws {
        let configuration = WizardryConfiguration()
        let data = try JSONEncoder().encode(configuration)
        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        dictionary["requireWake"] = false
        let migrated = try JSONDecoder().decode(WizardryConfiguration.self,from:JSONSerialization.data(withJSONObject:dictionary))
        XCTAssertEqual(migrated,configuration)
        var engine = GestureEngine()
        for i in 0...100 { XCTAssertNil(engine.update(roll:i.isMultiple(of:2) ? 1 : -1,pitch:0,acceleration:1.5,time:Double(i)*0.02)) }
        XCTAssertFalse(engine.isArmed)
    }

    func testThirtySecondStationaryHoldPreservesTargetAndNextStroke() {
        var tracker = VerticalVolumeTracker()
        tracker.begin(volume:0.37,acceleration:zero,gravity:gravity,time:0)
        for i in 1...3000 {
            XCTAssertEqual(tracker.update(acceleration:zero,gravity:gravity,rotation:0,time:Double(i)/100),0.37,accuracy:0.000001)
        }
        for i in 3001...3020 {
            _ = tracker.update(acceleration:.init(x:0,y:0,z:-0.1),gravity:gravity,rotation:0,time:Double(i)/100)
        }
        XCTAssertGreaterThan(tracker.target,0.37)
    }
    func testPhoneVolumeUsesTheSameOrderedExpiringSessionAndCannotCrossProfiles() {
        var configuration = WizardryConfiguration(); configuration.selectedProfileID = "phone"
        XCTAssertTrue(configuration.supportsLiveVolume)
        var gate = VolumeCommandGate()
        var request = VolumeRequest(sessionID:UUID(),revision:configuration.revision,sequence:0,createdAt:100,operation:.begin)
        XCTAssertTrue(gate.accept(request,configuration:configuration,now:100))
        XCTAssertFalse(gate.accept(request,configuration:configuration,now:100))
        request.id = UUID(); request.sequence = 1; request.operation = .update; request.target = 0.6
        XCTAssertTrue(gate.accept(request,configuration:configuration,now:100.1))
        configuration.selectedProfileID = "computer"
        request.id = UUID(); request.sequence = 2
        XCTAssertFalse(gate.accept(request,configuration:configuration,now:100.2))
        configuration.selectedProfileID = "phone"
        XCTAssertFalse(gate.accept(request,configuration:configuration,now:101.1))
        request.createdAt = 101.2; request.operation = .end
        XCTAssertTrue(gate.accept(request,configuration:configuration,now:101.2))
        request.id = UUID(); request.operation = .begin; request.sequence = 0; request.target = nil
        XCTAssertFalse(gate.accept(request,configuration:configuration,now:101.3))
        request.sessionID = UUID(); configuration.selectedProfileID = "home"
        XCTAssertFalse(configuration.supportsLiveVolume)
        XCTAssertFalse(gate.accept(request,configuration:configuration,now:101.3))
    }
    func testInterruptedPhoneSessionRequiresFreshActivationAndID() {
        var configuration = WizardryConfiguration(); configuration.selectedProfileID = "phone"
        var gate = VolumeCommandGate()
        var request = VolumeRequest(sessionID:UUID(),revision:configuration.revision,sequence:0,createdAt:100,operation:.begin)
        XCTAssertTrue(gate.accept(request,configuration:configuration,now:100))
        gate.invalidate(now:100.1)
        request.id = UUID(); request.sequence = 1; request.operation = .update; request.target = 0.6
        XCTAssertFalse(gate.accept(request,configuration:configuration,now:100.2))
        request.id = UUID(); request.sequence = 0; request.operation = .begin; request.target = nil
        XCTAssertFalse(gate.accept(request,configuration:configuration,now:100.2))
        request.sessionID = UUID()
        XCTAssertTrue(gate.accept(request,configuration:configuration,now:100.2))
    }
    func testVolumeReadbackMustConfirmRequestedLevelRatherThanSliderValue() {
        XCTAssertTrue(VolumeReadback.confirms(actual:0.604,target:0.6))
        XCTAssertFalse(VolumeReadback.confirms(actual:0.5,target:0.6))
        XCTAssertTrue(VolumeReadback.confirms(actual:0,target:0))
        XCTAssertTrue(VolumeReadback.confirms(actual:1,target:1))
        XCTAssertFalse(VolumeReadback.confirms(actual:.nan,target:0.6))
        XCTAssertFalse(VolumeReadback.confirms(actual:0.6,target:.infinity))
        XCTAssertFalse(VolumeReadback.confirms(actual:1.01,target:1))
        XCTAssertFalse(VolumeReadback.confirms(actual:0,target:-0.01))
    }
}
