import XCTest
@testable import GestureCore

final class ReceiverFailureTests: XCTestCase {
    private let token = "private-pairing-token"
    func testMissingRouteAndTokenMismatchAreDistinguished() {
        let missing = ReceiverFailure.message(status:404,data:Data("{\"error\":\"Not found\"}".utf8),token:token)
        XCTAssertTrue(missing.contains("HTTP 404")); XCTAssertTrue(missing.contains("updated receiver/server.py"))
        let denied = ReceiverFailure.message(status:401,data:Data("{\"error\":\"Unauthorized\"}".utf8),token:token)
        XCTAssertTrue(denied.contains("HTTP 401")); XCTAssertTrue(denied.contains("pairing token"))
    }
    func testActualSessionAndClockReasonsSurvive() {
        let session = ReceiverFailure.message(status:409,data:Data("{\"error\":\"Unknown session or older sequence\"}".utf8),token:token)
        XCTAssertTrue(session.contains("Unknown session or older sequence"))
        let expired = ReceiverFailure.message(status:408,data:Data("{\"error\":\"Live volume request expired\"}".utf8),token:token)
        XCTAssertTrue(expired.contains("one-second")); XCTAssertTrue(expired.contains("clock"))
    }
    func testCredentialsAndUnexpectedHTMLAreNotDisplayed() {
        let data = Data("{\"error\":\"Unauthorized: private-pairing-token\"}".utf8)
        let message = ReceiverFailure.message(status:401,data:data,token:token)
        XCTAssertFalse(message.contains(token)); XCTAssertTrue(message.contains("[redacted]"))
        let html = ReceiverFailure.message(status:502,data:Data("<html>private</html>".utf8),token:token)
        XCTAssertTrue(html.contains("HTTP 502")); XCTAssertFalse(html.contains("<html>"))
    }
}
