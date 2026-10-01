import XCTest
@testable import GestureCore

final class WatchControlSnapshotTests: XCTestCase {
    func testOldTelemetryWithoutControlSnapshotStillDecodes() throws {
        let frame = MotionFrame(time:100,roll:0,pitch:0,yaw:1,ax:0,ay:0,az:0,rx:0,ry:0,rz:0,gx:0,gy:0,gz:-1,hz:100,state:"Ready")
        var dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(frame)) as? [String:Any])
        dictionary.removeValue(forKey:"control")
        let decoded = try JSONDecoder().decode(MotionFrame.self,from:JSONSerialization.data(withJSONObject:dictionary))
        XCTAssertNil(decoded.control)
        XCTAssertEqual(decoded.yaw,1)
    }
    func testVolumeStatusRoundTripAndInvalidTelemetry() throws {
        var snapshot = WatchControlSnapshot(phase:.adjustingVolume,profileID:"computer",relativeYaw:.pi/2,
                                           requestedVolume:0.6,acknowledgedVolume:0.58,dryRun:false,
                                           singleTapEnabled:true,singleTapStatus:"Enabled",armRemaining:0,enrollmentRemaining:nil)
        XCTAssertTrue(snapshot.isValid)
        XCTAssertEqual(try JSONDecoder().decode(WatchControlSnapshot.self,from:JSONEncoder().encode(snapshot)),snapshot)
        snapshot.relativeYaw = .nan; XCTAssertFalse(snapshot.isValid)
        snapshot.relativeYaw = .pi/2; snapshot.requestedVolume = 1.1; XCTAssertFalse(snapshot.isValid)
        snapshot.requestedVolume = 0.6; snapshot.enrollmentRemaining = 301; XCTAssertFalse(snapshot.isValid)
    }
}
