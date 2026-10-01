import XCTest
@testable import GestureCore

final class VolumeInteractionTests: XCTestCase {
    private let zero = MotionVector(x:0,y:0,z:0)
    private let gravity = MotionVector(x:0,y:0,z:-1)
    private func pose(_ radians: Double) -> MotionQuaternion {
        .init(x:sin(radians/2),y:0,z:0,w:cos(radians/2))
    }
    func testOrthogonalEntryRequiresSettlingAndWorksOnEitherWrist() {
        for sign in [-1.0,1.0] {
            var arbiter = ExtensionArbiter(); arbiter.calibrate(pose(0))
            XCTAssertEqual(arbiter.update(attitude:pose(sign * .pi/2),acceleration:0,rotation:1,time:0),.transition)
            XCTAssertEqual(arbiter.update(attitude:pose(sign * .pi/2),acceleration:0,rotation:0,time:0.1),.transition)
            XCTAssertEqual(arbiter.update(attitude:pose(sign * .pi/2),acceleration:0,rotation:0,time:0.36),.enterVolume)
            XCTAssertTrue(arbiter.isViewing(pose(0.1)))
            XCTAssertFalse(arbiter.isViewing(pose(.pi/2)))
        }
    }
    func testLegacyPoseAndShakeRemainAvailableButTransitionsCannotFire() {
        var arbiter = ExtensionArbiter(); arbiter.calibrate(pose(0))
        XCTAssertEqual(arbiter.update(attitude:pose(0),acceleration:1.5,rotation:0,time:0),.legacy)
        XCTAssertEqual(arbiter.update(attitude:pose(0.7),acceleration:0,rotation:0,time:0.1),.transition)
        XCTAssertEqual(arbiter.update(attitude:pose(0.7),acceleration:0,rotation:0,time:0.4),.legacy)
        var engine = GestureEngine()
        engine.calibrateAndArm(roll:0,pitch:0,sampleTime:0,readyTime:0)
        for i in 1...50 {
            XCTAssertNil(engine.update(roll:0.9,pitch:0,acceleration:0,time:Double(i)*0.01,suppressActions:true))
        }
        var events: [GestureEngine.Event] = []
        for i in 51...75 {
            if let event = engine.update(roll:0.9,pitch:0,acceleration:0,time:Double(i)*0.01) { events.append(event) }
        }
        XCTAssertEqual(events,[.action(.rollPositive)])
        // Suppression cannot erase cooldown / return-to-neutral requirement.
        _ = engine.update(roll:0.9,pitch:0,acceleration:0,time:0.76,suppressActions:true)
        for i in 77...100 { XCTAssertNil(engine.update(roll:0.9,pitch:0,acceleration:0,time:Double(i)*0.01)) }
    }
    func testQuaternionSignWrapAndInvalidPose() {
        let q = pose(.pi/2)
        let reverse = MotionQuaternion(x:-q.x,y:-q.y,z:-q.z,w:-q.w)
        XCTAssertEqual(q.normal,reverse.normal)
        XCTAssertNil(MotionQuaternion(x:0,y:0,z:0,w:0).normal)
        XCTAssertNil(MotionQuaternion(x:.nan,y:0,z:0,w:1).normal)
        var arbiter = ExtensionArbiter(); arbiter.calibrate(pose(3.13))
        XCTAssertTrue(arbiter.isViewing(pose(-3.13)))
    }
    func testVerticalProjectionReversalsPauseAndBounds() {
        XCTAssertEqual(VerticalVolumeTracker.vertical(.init(x:0,y:0,z:0.1),gravity),0.980665,accuracy:0.00001)
        XCTAssertEqual(VerticalVolumeTracker.vertical(.init(x:0.1,y:0,z:0),gravity),0,accuracy:0.00001)
        var tracker = VerticalVolumeTracker()
        tracker.begin(volume:0.5,acceleration:zero,gravity:gravity,time:0)
        for i in 1...20 { _ = tracker.update(acceleration:.init(x:0,y:0,z:0.1),gravity:gravity,rotation:0,time:Double(i)*0.01) }
        XCTAssertGreaterThan(tracker.target,0.5)
        for i in 21...100 { _ = tracker.update(acceleration:zero,gravity:gravity,rotation:0,time:Double(i)*0.01) }
        XCTAssertEqual(tracker.velocity,0)
        let held = tracker.target
        for i in 101...600 { _ = tracker.update(acceleration:zero,gravity:gravity,rotation:0,time:Double(i)*0.01) }
        XCTAssertEqual(tracker.target,held)
        for i in 601...620 { _ = tracker.update(acceleration:.init(x:0,y:0,z:-0.1),gravity:gravity,rotation:0,time:Double(i)*0.01) }
        XCTAssertLessThan(tracker.target,held)
        for i in 621...900 { _ = tracker.update(acceleration:.init(x:0,y:0,z:-1),gravity:gravity,rotation:0,time:Double(i)*0.01) }
        XCTAssertEqual(tracker.target,0)
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
}
