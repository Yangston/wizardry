import XCTest
@testable import GestureCore

final class InteractionDiagnosticsTests: XCTestCase {
    func testDistinguishesSensorCadenceFromMainActorDelay() {
        var diagnostics = InteractionDiagnostics()
        for i in 0...100 {
            let sample = 10+Double(i)/100
            diagnostics.observe(sample:sample,callback:sample+0.002,processed:sample+0.082,rawRate:100)
        }
        XCTAssertEqual(diagnostics.motionHz,100,accuracy:0.01)
        XCTAssertEqual(diagnostics.processingDelayMS,80,accuracy:0.01)
        XCTAssertEqual(diagnostics.sampleAgeMS,82,accuracy:0.01)
        diagnostics.observe(sample:11.4,callback:11.402,processed:11.403,rawRate:95)
        XCTAssertEqual(diagnostics.maximumGapMS,400,accuracy:0.01)
        diagnostics.beginCapture()
        XCTAssertEqual(diagnostics.motionHz,0)
        XCTAssertEqual(diagnostics.maximumGapMS,0)
    }

    func testBoundedTraceRetainsEvidenceBeforeRelease() {
        var diagnostics = InteractionDiagnostics()
        for i in 0..<100 {
            diagnostics.record(.init(uptime:Double(i),event:"scene:inactive",scene:"inactive",application:"inactive",
                                     requested:true,enabled:true,rotated:false,reducedLuminance:true))
        }
        diagnostics.record(.init(uptime:100,event:"release:background",scene:"background",application:"background",
                                 requested:true,enabled:true,rotated:false,reducedLuminance:true),stop:.background)
        XCTAssertEqual(diagnostics.events.count,48)
        XCTAssertEqual(diagnostics.lastStop,.background)
        XCTAssertEqual(diagnostics.events.last?.enabled,true)
    }
}
