import XCTest

final class PhoneUITests: XCTestCase {
    func testCompanionScreensAndMappingEditor() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Wizardry"].waitForExistence(timeout:15))
        capture("01-control")
        app.tabBars.buttons["Motions"].tap()
        XCTAssertTrue(app.navigationBars["Motions"].waitForExistence(timeout:5))
        capture("02-motions")
        app.staticTexts["Twist +"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Twist +"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["Save"].exists)
        capture("03-mapping")
        app.buttons["Save"].tap()
        app.tabBars.buttons["Live"].tap()
        XCTAssertTrue(app.staticTexts["Waiting for live motion"].waitForExistence(timeout:5))
        capture("04-live")
        app.tabBars.buttons["Setup"].tap()
        XCTAssertTrue(app.navigationBars["Setup"].waitForExistence(timeout:5))
        capture("05-setup")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
