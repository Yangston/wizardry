import XCTest
@testable import GestureCore

final class ConnectionAndSensorTests: XCTestCase {
    func testLegacyConfigurationKeepsConnectionAndExplicitDisconnectBlocksCommands() throws {
        var configuration = WizardryConfiguration()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(configuration)) as? [String:Any])
        json.removeValue(forKey:"controlConnectionEnabled")
        XCTAssertTrue(try JSONDecoder().decode(WizardryConfiguration.self,from:JSONSerialization.data(withJSONObject:json)).allowsControl)
        configuration.controlConnectionEnabled = false
        var gate = CommandGate()
        let event = GestureRequest(createdAt:100,revision:configuration.revision,profileID:"computer",gesture:.rollPositive)
        XCTAssertNil(gate.accept(event,configuration:configuration,now:100))
        var coordinator = VolumeCommandCoordinator()
        let request = VolumeRequest(sessionID:UUID(),revision:configuration.revision,sequence:0,createdAt:100,operation:.begin,target:nil,profileID:"computer")
        assertRejected(coordinator.receive(request,ticket:UUID(),configuration:configuration,now:100))
    }
    func testVolumeRequestCannotCrossTargetsWithSameRevision() {
        let configuration = WizardryConfiguration()
        var coordinator = VolumeCommandCoordinator()
        let request = VolumeRequest(sessionID:UUID(),revision:configuration.revision,sequence:0,createdAt:100,operation:.begin,target:nil,profileID:"phone")
        assertRejected(coordinator.receive(request,ticket:UUID(),configuration:configuration,now:100))
        XCTAssertFalse(coordinator.hasSession)
    }
    func testUnchangedPhoneVolumeCannotConfirmSmallRequestedMovement() {
        XCTAssertFalse(VolumeReadback.confirms(actual:0.5,target:0.505,previous:0.5))
        XCTAssertFalse(VolumeReadback.confirms(actual:0.501,target:0.495,previous:0.5))
        XCTAssertTrue(VolumeReadback.confirms(actual:0.505,target:0.505,previous:0.5))
        XCTAssertTrue(VolumeReadback.confirms(actual:0.495,target:0.495,previous:0.5))
        XCTAssertTrue(VolumeReadback.confirms(actual:0.5,target:0.5,previous:0.5))
        XCTAssertFalse(VolumeReadback.confirms(actual:.nan,target:0.5,previous:0.5))
    }
    func testMappingEditRejectsStaleAndCrossTargetChangesButPreservesUntouchedLegacyBindings() {
        var configuration = WizardryConfiguration()
        configuration.profiles[0].bindings[0].action = .phonePing // Existing legacy value stays stored.
        var bindings = configuration.profiles[0].bindings
        bindings[1].action = .mute
        var edit = DesktopMappingEdit(id:UUID(),revision:configuration.revision,profileID:"computer",bindings:bindings)
        XCTAssertEqual(edit.applying(to:configuration)?.profiles[0].bindings[0].action,.phonePing)
        edit.bindings[1].action = .phoneNext
        XCTAssertNil(edit.applying(to:configuration))
        edit.bindings = bindings; edit.revision = "stale"
        XCTAssertNil(edit.applying(to:configuration))
        XCTAssertFalse(ActionKind.volumeUp.isAllowed(inProfile:"phone"))
        XCTAssertTrue(ActionKind.phonePing.isAllowed(inProfile:"home"))
    }
    func testSensorBatchPreservesNativeSamplesAndRejectsInvalidOrReorderedData() throws {
        let frame = SensorFrame(time:1,wallTime:100,ax:0.1,ay:0.2,az:0.3,rx:1,ry:2,rz:3,
                                gx:0,gy:0,gz:-1,roll:0.4,pitch:0.5,yaw:0.6,qx:0,qy:0,qz:0,qw:1)
        var next = frame; next.time = 1.01; next.wallTime = 100.01
        var batch = SensorBatch(sessionID:UUID(),batchSequence:0,createdAt:100.02,samples:[frame,next],droppedSamples:0,recording:true,metadata:nil)
        XCTAssertTrue(batch.isValid)
        let decoded = try JSONDecoder().decode(SensorBatch.self,from:JSONEncoder().encode(batch))
        XCTAssertEqual(decoded.samples.count,2)
        XCTAssertEqual(decoded.samples[1].time,1.01)
        XCTAssertNil(decoded.samples[0].rawAx)
        batch.samples = [next,frame]; XCTAssertFalse(batch.isValid)
        batch.samples = [frame]; batch.samples[0].rawAx = .infinity; XCTAssertFalse(batch.isValid)
    }
    private func assertRejected(_ effects: [VolumeCommandCoordinator.Effect],file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertEqual(effects.count,1,file:file,line:line)
        for effect in effects {
            if case .reply(_,_,let reply) = effect { XCTAssertEqual(reply.outcome,.failed,file:file,line:line) }
            else { XCTFail("Rejected input must never execute",file:file,line:line) }
        }
    }
}
