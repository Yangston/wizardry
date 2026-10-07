import XCTest
@testable import GestureCore

final class VolumeInteractionTests: XCTestCase {
    private func pose(_ radians: Double) -> MotionQuaternion {
        .init(x:sin(radians/2),y:0,z:0,w:cos(radians/2))
    }
    func testYawEntryCrossesFiftyFiveImmediatelyFromAnyHeadingOnEitherWrist() {
        for origin in [0.0,0.7,3.13,-3.13] {
            for sign in [-1.0,1.0] {
                var arbiter = ExtensionArbiter(); arbiter.calibrate(yaw:origin)
                let before = ExtensionArbiter.offset(origin + sign * 54.9 * .pi/180,from:0)
                let extended = ExtensionArbiter.offset(origin + sign * 55 * .pi/180,from:0)
                XCTAssertEqual(arbiter.update(yaw:before,acceleration:0.8,rotation:3,time:0),.transition)
                XCTAssertEqual(arbiter.update(yaw:extended,acceleration:0.8,rotation:3,time:0.01),.enterVolume)
                XCTAssertEqual(arbiter.relativeYaw,sign * 55 * .pi/180,accuracy:0.00001)
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
        XCTAssertEqual(arbiter.update(yaw:.pi/2,acceleration:0,rotation:2,time:0),.enterVolume)
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
    func testGapDuplicateAndInvalidSamplesCannotEnterVolume() {
        var arbiter = ExtensionArbiter(); arbiter.calibrate(yaw:0)
        _ = arbiter.update(yaw:.pi/2,acceleration:0,rotation:0,time:0)
        XCTAssertEqual(arbiter.update(yaw:.pi/2,acceleration:0,rotation:0,time:1),.transition)
        XCTAssertEqual(arbiter.update(yaw:.pi/2,acceleration:0,rotation:0,time:1),.transition)
        XCTAssertEqual(arbiter.update(yaw:.nan,acceleration:0,rotation:0,time:1.1),.transition)
        XCTAssertEqual(arbiter.update(yaw:.pi/2,acceleration:0,rotation:0,time:1.2),.transition)
        XCTAssertEqual(arbiter.update(yaw:.pi/2,acceleration:0,rotation:3,time:1.21),.enterVolume)
    }
    func testEntryHasNoUpperAngleCutoffAndExtensionProgressKeepsPriority() {
        for degrees in [55.0,90,120,179] {
            for sign in [-1.0,1.0] {
                var arbiter = ExtensionArbiter(); arbiter.calibrate(yaw:0)
                XCTAssertEqual(arbiter.update(yaw:sign*degrees * .pi/180,acceleration:0.2,rotation:4,time:0),.enterVolume)
            }
        }
        var arbiter = ExtensionArbiter(); arbiter.calibrate(yaw:0)
        for i in 0...100 {
            XCTAssertEqual(arbiter.update(yaw:45 * .pi/180,acceleration:0,rotation:0,time:Double(i)/100),.transition)
        }
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
