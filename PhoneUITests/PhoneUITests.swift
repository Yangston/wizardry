import XCTest

final class PhoneUITests: XCTestCase {
    func testCompanionScreensAndMappingEditor() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Wizardry"].waitForExistence(timeout:15))
        XCTAssertTrue(app.staticTexts["Live Watch status"].exists)
        XCTAssertTrue(app.staticTexts["Activate · Extend · Adjust · Lock"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@", "2.5 seconds")).firstMatch.exists)
        capture("01-control")
        let tapSetup = app.buttons["Single finger tap setup"].firstMatch
        for _ in 0..<6 {
            if tapSetup.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(tapSetup.isHittable)
        tapSetup.tap()
        XCTAssertTrue(app.navigationBars["Learn single tap"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Open Wizardry → Learn single finger tap."].exists)
        capture("01b-tap-setup")
        app.navigationBars.buttons.firstMatch.tap()
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
