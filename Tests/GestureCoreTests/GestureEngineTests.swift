import XCTest
@testable import GestureCore

final class GestureEngineTests: XCTestCase {
    func testTwistsCannotArmAndExplicitArmRequiresSettling() {
        var engine = GestureEngine()
        _ = engine.update(roll:0,pitch:0,acceleration:0,time:0)
        for (index,angle) in [0.6,-0.6,0.6,-0.6].enumerated() {
            let event = engine.update(roll:angle,pitch:0,acceleration:0,time:Double(index+1)*0.2)
            XCTAssertNil(event)
        }
        XCTAssertFalse(engine.isArmed)
        engine.arm(time:0.8)
        XCTAssertNil(engine.update(roll:0.9,pitch:0,acceleration:0,time:1.0))
        for i in 51...70 { XCTAssertNil(engine.update(roll:0,pitch:0,acceleration:0,time:Double(i)*0.02)) }
        var events: [GestureEngine.Event] = []
        for i in 71...100 {
            if let event = engine.update(roll:0.9,pitch:0,acceleration:0,time:Double(i)*0.02) { events.append(event) }
        }
        XCTAssertEqual(events,[.action(.rollPositive)])
    }
    func testDisarmedGesturesNeverActAndSensorGapDisarms() {
        var engine = GestureEngine()
        for i in 0..<60 { XCTAssertNil(engine.update(roll:i < 10 ? 0 : 0.9,pitch:0,acceleration:0,time:Double(i)*0.02)) }
        engine.arm(time:1.2)
        XCTAssertNil(engine.update(roll:1,pitch:1,acceleration:0,time:5))
        XCTAssertFalse(engine.isArmed)
        XCTAssertNil(engine.update(roll:.nan,pitch:0,acceleration:0,time:5.02))
    }
    func testPitchAndDoubleShakeRequireNeutralAndCooldown() {
        var e = GestureEngine(); e.arm(time:0)
        for i in 0...20 { _ = e.update(roll:0,pitch:0,acceleration:0,time:Double(i)*0.02) }
        var events: [GestureEngine.Event] = []
        for i in 21...45 { if let event = e.update(roll:0,pitch:0.9,acceleration:0,time:Double(i)*0.02) { events.append(event) } }
        for i in 46...95 { _ = e.update(roll:0,pitch:0,acceleration:0,time:Double(i)*0.02) }
        _ = e.update(roll:0,pitch:0,acceleration:1.5,time:1.92)
        _ = e.update(roll:0,pitch:0,acceleration:0,time:2.0)
        if let event = e.update(roll:0,pitch:0,acceleration:1.5,time:2.2) { events.append(event) }
        XCTAssertEqual(events,[.action(.pitchUp),.action(.shake)])
        XCTAssertNil(e.update(roll:0,pitch:0,acceleration:1.5,time:2.22))
    }
    func testArmExpiresAndAngleWrapDoesNotTrigger() {
        var e = GestureEngine()
        _ = e.update(roll:3.1,pitch:0,acceleration:0,time:0)
        for i in 1...50 { XCTAssertNil(e.update(roll:-3.1,pitch:0,acceleration:0,time:Double(i)*0.02)) }
        XCTAssertFalse(e.isArmed)
        e.arm(time:1); e.armSeconds = 3
        for i in 51...500 { _ = e.update(roll:3.1,pitch:0,acceleration:0,time:Double(i)*0.02) }
        XCTAssertFalse(e.isArmed)
    }
    func testCommandGateRejectsStaleDuplicateDisabledAndDifferentSettings() {
        var configuration = WizardryConfiguration(); var gate = CommandGate()
        var event = GestureRequest(createdAt:100,revision:configuration.revision,profileID:"computer",gesture:.rollPositive)
        XCTAssertNotNil(gate.accept(event,configuration:configuration,now:100))
        XCTAssertNil(gate.accept(event,configuration:configuration,now:101))
        event.id = UUID(); event.createdAt = 90
        XCTAssertNil(gate.accept(event,configuration:configuration,now:101))
        event.createdAt = 101; event.revision = "old"
        XCTAssertNil(gate.accept(event,configuration:configuration,now:101))
        event.revision = configuration.revision; configuration.profiles[0].bindings[0].enabled = false
        XCTAssertNil(gate.accept(event,configuration:configuration,now:101))
    }
    func testConfigurationRoundTripAndValidation() throws {
        let config = WizardryConfiguration()
        XCTAssertEqual(try JSONDecoder().decode(WizardryConfiguration.self,from:JSONEncoder().encode(config)),config)
        XCTAssertTrue(config.isValid)
        var invalid = config; invalid.profiles = []; XCTAssertFalse(invalid.isValid)
        invalid = config; invalid.threshold = .nan; XCTAssertFalse(invalid.isValid)
        invalid = config; invalid.profiles[0].bindings.append(invalid.profiles[0].bindings[0]); XCTAssertFalse(invalid.isValid)
    }
}
