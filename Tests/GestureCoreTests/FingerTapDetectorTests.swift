import XCTest
@testable import GestureCore

final class FingerTapDetectorTests: XCTestCase {
    private func run(_ detector: inout FingerTapDetector, peaks: [Int], suppressed: Bool = false) -> ([FingerTapDetector.Event],[FingerTapDetector.Observation]) {
        if suppressed { detector.suppress(until:1) }
        var events: [FingerTapDetector.Event] = [], observations: [FingerTapDetector.Observation] = []
        for i in 0...180 {
            let output = detector.update(raw:.init(x:peaks.contains(i) ? 0.3 : 0,y:0,z:1),rotation:.init(x:0,y:0,z:0),time:Double(i)*0.01)
            if let event = output.event { events.append(event) }
            if let observation = output.observation { observations.append(observation) }
        }
        return (events,observations)
    }
    private func model() -> FingerTapModel {
        var detector = FingerTapDetector()
        let sample = run(&detector,peaks:[20]).1[0].template
        let negative = TapTemplate(features:Array(repeating:Array(repeating:1.0,count:6),count:sample.features.count))
        return .init(positive:Array(repeating:sample,count:5),negative:Array(repeating:negative,count:5),threshold:0.02,validated:true)
    }
    func testSingleTouchDelaysDispatchAndDoubleTouchCancels() {
        var detector = FingerTapDetector(model:model())
        let single = run(&detector,peaks:[20])
        XCTAssertEqual(single.0.count,1)
        XCTAssertEqual(single.0.first?.time ?? -1,0.2,accuracy:0.01)
        detector = FingerTapDetector(model:model())
        XCTAssertTrue(run(&detector,peaks:[20,50]).0.isEmpty)
    }
    func testUnvalidatedModelHapticsAndResetCannotDispatch() {
        var draft = model(); draft.validated = false
        var detector = FingerTapDetector(model:draft)
        XCTAssertTrue(run(&detector,peaks:[20]).0.isEmpty)
        detector = FingerTapDetector(model:model())
        XCTAssertTrue(run(&detector,peaks:[20],suppressed:true).0.isEmpty)
        detector.reset()
        XCTAssertNil(detector.update(raw:.init(x:.nan,y:0,z:0),rotation:.init(x:0,y:0,z:0),time:2).event)
    }
    func testPendingTapDoesNotSurviveGapOrActivationReset() {
        for reset in [false,true] {
            var detector = FingerTapDetector(model:model())
            for i in 0...45 {
                _ = detector.update(raw:.init(x:i == 20 ? 0.3 : 0,y:0,z:1),rotation:.init(x:0,y:0,z:0),time:Double(i)*0.01)
            }
            if reset { detector.reset() }
            XCTAssertNil(detector.update(raw:.init(x:0,y:0,z:1),rotation:.init(x:0,y:0,z:0),time:1).event)
        }
    }
    func testDTWValidationAndNegativeRejection() {
        let good = model()
        XCTAssertTrue(good.isValid)
        XCTAssertTrue(good.recognizes(good.positive[0]))
        XCTAssertFalse(good.recognizes(good.negative[0]))
        XCTAssertEqual(TapTemplate.distance(good.positive[0],good.positive[0]),0)
        XCTAssertEqual(TapTemplate.distance(.init(features:[]),good.positive[0]),.infinity)
    }
    func testEnrollmentRequiresHeldOutTapsAndFiveMinuteNegativeStage() {
        let good = model()
        var enrollment = TapEnrollment()
        for _ in 0...1 {
            for i in 0..<20 { enrollment.observe(.init(time:Double(i),template:good.positive[0],recognized:false)) }
            enrollment.finishStage()
        }
        for i in 0..<10 { enrollment.observe(.init(time:Double(i),template:good.negative[0],recognized:false)) }
        enrollment.finishStage()
        XCTAssertEqual(enrollment.stage,.validationTaps)
        for i in 0..<20 { enrollment.observe(.init(time:Double(i),template:good.positive[0],recognized:false)) }
        enrollment.finishStage()
        XCTAssertNil(enrollment.model)
        XCTAssertEqual(enrollment.stage.duration,300)
        for i in 0..<10 { enrollment.observe(.init(time:Double(i),template:good.negative[0],recognized:false)) }
        enrollment.finishStage()
        XCTAssertTrue(enrollment.model?.validated == true)
    }
}
