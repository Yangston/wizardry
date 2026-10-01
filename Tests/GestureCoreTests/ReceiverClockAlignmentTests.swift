import XCTest
@testable import GestureCore

final class ReceiverClockAlignmentTests: XCTestCase {
    func testClockSkewCorrectedWithoutChangingRequestAge() throws {
        for offset in [-4.0,1.35,10.0] {
            let sample = ReceiverClockAlignment(serverTime:100+offset,receivedAt:100.02)
            let wire = try XCTUnwrap(sample.translate(createdAt:100.1,now:100.2))
            let receiverNow = 100.2+offset
            XCTAssertEqual(receiverNow-wire,0.12,accuracy:0.00001) // 100 ms age + 20 ms return delay
        }
    }
    func testExpiredOriginalRequestCannotBecomeFreshAfterTranslation() {
        let sample = ReceiverClockAlignment(serverTime:104,receivedAt:100)
        XCTAssertNil(sample.translate(createdAt:99,now:100.01))
        XCTAssertNil(sample.translate(createdAt:100.3,now:100.01))
        XCTAssertNil(sample.translate(createdAt:131,now:131)) // stale clock sample
    }
    func testInvalidClockAndReturnTripDelayNeverMakeRequestYounger() throws {
        XCTAssertNil(ReceiverClockAlignment(serverTime:.nan,receivedAt:100).translate(createdAt:100,now:100))
        let sample = ReceiverClockAlignment(serverTime:105,receivedAt:100.2)
        let wire = try XCTUnwrap(sample.translate(createdAt:100.3,now:100.4))
        XCTAssertGreaterThanOrEqual((100.4+5)-wire,100.4-100.3)
    }
}
