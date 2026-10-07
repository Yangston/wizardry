import XCTest

final class PhoneConnectionTests: XCTestCase {
    func testStudioToggleDoesNotChangeThePhoneCommandTarget() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.navigationBars["Wizardry"].waitForExistence(timeout:15))
        app.segmentedControls.buttons["Phone"].tap()
        app.tabBars.buttons["Live"].tap()
        let toggle = app.switches["computer-studio-toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout:5))
        reveal(toggle,in:app)
        setSwitch(toggle,to:true)
        setSwitch(toggle,to:false)
        app.tabBars.buttons["Control"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["Phone"].isSelected)
        app.segmentedControls.buttons["Computer"].tap()
    }

    func testExplicitConnectionAndPhoneReadinessRemainSeparateFromPairing() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.navigationBars["Wizardry"].waitForExistence(timeout:15))
        app.segmentedControls.buttons["Phone"].tap()
        let readiness = app.descendants(matching:.any).matching(identifier:"phone-volume-readiness").firstMatch
        XCTAssertTrue(readiness.waitForExistence(timeout:5))
        // Simulator refusal is honest readiness, not evidence of working audio.
        XCTAssertTrue(readiness.label.contains("physical iPhone"))
        let disconnect = app.buttons["disconnect-watch-control"].firstMatch
        reveal(disconnect,in:app)
        if disconnect.isEnabled { disconnect.tap() }
        let status = app.descendants(matching:.any).matching(identifier:"control-target-status").firstMatch
        XCTAssertTrue(status.label.contains("disconnected"))
        XCTAssertFalse(disconnect.isEnabled)
        app.buttons["connect-watch-control"].firstMatch.tap()
        XCTAssertTrue(status.label.contains("Phone"))
        XCTAssertTrue(disconnect.isEnabled)
        for _ in 0..<5 {
            if app.segmentedControls.buttons["Computer"].isHittable { break }
            app.swipeDown()
        }
        app.segmentedControls.buttons["Computer"].tap()
        XCTAssertTrue(status.label.contains("Computer"))
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            let viewport = app.scrollViews.firstMatch.frame.insetBy(dx:0,dy:12)
            if element.isHittable && viewport.contains(element.frame) { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
    private func setSwitch(_ element: XCUIElement, to enabled: Bool) {
        let desired = enabled ? "1" : "0"
        if element.value as? String != desired {
            // SwiftUI exposes the full labeled row as a switch. Hit its native
            // trailing control rather than the label or a clipped row center.
            element.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.5)).tap()
        }
        let changed = XCTNSPredicateExpectation(predicate:NSPredicate(format:"value == %@",desired),object:element)
        XCTAssertEqual(XCTWaiter.wait(for:[changed],timeout:5),.completed)
    }
}
