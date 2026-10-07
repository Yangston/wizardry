import XCTest
@testable import GestureCore

@MainActor
private final class FakeRuntimeDriver: InteractionRuntimeDriver {
    var didStart: (() -> Void)?
    var didStop: ((String) -> Void)?
    var starts = 0
    var invalidations = 0
    var failOnStart = false
    func start() {
        starts += 1
        if failOnStart { didStop?("System denied runtime") }
    }
    func invalidate() { invalidations += 1 }
}

final class InteractionRuntimeTests: XCTestCase {
    @MainActor
    func testCalibrationReadyVolumeAndFinalAcknowledgementShareOneLease() async {
        var now = 10.0
        let driver = FakeRuntimeDriver()
        let runtime = InteractionRuntime(clock:{now},makeDriver:{driver})
        XCTAssertTrue(runtime.start(until:20,canStart:true))
        driver.didStart?()
        now = 10.3
        XCTAssertTrue(runtime.continueThroughArming(until:18.3))
        now = 11
        XCTAssertTrue(runtime.continueThroughVolume(until:1800))
        XCTAssertEqual(driver.starts,1)
        XCTAssertEqual(driver.invalidations,0)
        XCTAssertEqual(runtime.deadline,610)
        // Beginning a final write is not a runtime stop; the owner releases it
        // only when final readback arrives (or a deadline/interruption occurs).
        now = 41.2 // A 30-second stationary hold does not release autorotation.
        XCTAssertFalse(runtime.expireIfNeeded())
        XCTAssertTrue(runtime.isRequested)
        runtime.stop(reason:.volumeLocked)
        XCTAssertEqual(driver.invalidations,1)
    }

    @MainActor
    func testStopDiagnosticsRunBeforeDriverReleaseAndAfterCleanup() async {
        let driver = FakeRuntimeDriver()
        let runtime = InteractionRuntime(clock:{10},makeDriver:{driver})
        var reasons: [InteractionEndReason] = []
        runtime.willStop = { reason in
            XCTAssertTrue(runtime.isRequested)
            XCTAssertEqual(driver.invalidations,0)
            reasons.append(reason)
        }
        runtime.didStop = {
            XCTAssertFalse(runtime.isRequested)
            XCTAssertEqual(driver.invalidations,1)
        }
        XCTAssertTrue(runtime.start(until:20,canStart:true))
        runtime.stop(reason:.background)
        runtime.stop(reason:.explicitStop)
        XCTAssertEqual(reasons,[.background])
    }

    @MainActor
    func testExpiryWithoutMotionStopsPendingSessionAndCannotBeRevivedByLateStart() async {
        var now = 10.0
        let driver = FakeRuntimeDriver()
        let runtime = InteractionRuntime(clock:{ now },makeDriver:{ driver })
        var interruptions: [String] = []
        runtime.interrupted = { interruptions.append($0) }
        XCTAssertTrue(runtime.start(until:18,canStart:true))
        let lateStart = driver.didStart
        now = 18
        XCTAssertTrue(runtime.expireIfNeeded())
        lateStart?()
        XCTAssertFalse(runtime.isRequested)
        XCTAssertFalse(runtime.isRunning)
        XCTAssertNil(runtime.deadline)
        XCTAssertEqual(driver.invalidations,1)
        XCTAssertEqual(interruptions.count,1)
    }

    @MainActor
    func testExplicitStopAndReactivationIgnorePreviousSessionCallbacks() async {
        let old = FakeRuntimeDriver(), next = FakeRuntimeDriver()
        var drivers = [old,next]
        let runtime = InteractionRuntime(clock:{ 10 },makeDriver:{ drivers.removeFirst() })
        var interruptions: [String] = []
        runtime.interrupted = { interruptions.append($0) }
        XCTAssertTrue(runtime.start(until:18,canStart:true))
        let lateStart = old.didStart, lateStop = old.didStop
        runtime.stop()
        XCTAssertTrue(runtime.start(until:20,canStart:true))
        next.didStart?()
        lateStart?(); lateStop?("Old session expired")
        XCTAssertTrue(runtime.isRunning)
        XCTAssertEqual(runtime.deadline,20)
        XCTAssertEqual(old.invalidations,1)
        XCTAssertEqual(next.invalidations,0)
        XCTAssertTrue(interruptions.isEmpty)
    }

    @MainActor
    func testDeniedRuntimeDisarmsOwnerAndNeverRetries() async {
        let driver = FakeRuntimeDriver()
        driver.failOnStart = true
        let runtime = InteractionRuntime(clock:{ 10 },makeDriver:{ driver })
        var interruptions: [String] = []
        runtime.interrupted = { interruptions.append($0) }
        XCTAssertFalse(runtime.start(until:18,canStart:true))
        for _ in 0..<10 { XCTAssertFalse(runtime.expireIfNeeded()) }
        XCTAssertEqual(driver.starts,1)
        XCTAssertFalse(runtime.isRequested)
        XCTAssertEqual(interruptions,["System denied runtime"])
    }

    @MainActor
    func testInactiveOrExpiredActivationCannotRequestOSRuntime() async {
        let driver = FakeRuntimeDriver()
        let runtime = InteractionRuntime(clock:{ 10 },makeDriver:{ driver })
        XCTAssertFalse(runtime.start(until:18,canStart:false))
        XCTAssertFalse(runtime.start(until:10,canStart:true))
        XCTAssertFalse(runtime.start(until:.infinity,canStart:true))
        XCTAssertEqual(driver.starts,0)
    }

    @MainActor
    func testVolumeUsesSameSessionAndCannotExtendPastItsOriginalOSCap() async {
        var now = 10.0
        let driver = FakeRuntimeDriver()
        let runtime = InteractionRuntime(clock:{ now },makeDriver:{ driver })
        XCTAssertTrue(runtime.start(until:18,canStart:true))
        driver.didStart?()
        now = 12
        runtime.continueThroughVolume(until:1800)
        XCTAssertEqual(runtime.deadline,610)
        now = 18
        XCTAssertFalse(runtime.expireIfNeeded())
        runtime.continueThroughVolume(until:1800)
        XCTAssertEqual(runtime.deadline,610)
        XCTAssertEqual(driver.starts,1)
        now = 610
        XCTAssertTrue(runtime.expireIfNeeded())
        runtime.continueThroughVolume(until:1800)
        XCTAssertFalse(runtime.isRequested)
        XCTAssertEqual(driver.starts,1)
    }

    @MainActor
    func testVolumeStopInvalidatesRuntimeBeforeItsOriginalArmDeadline() async {
        let driver = FakeRuntimeDriver()
        let runtime = InteractionRuntime(clock:{ 10 },makeDriver:{ driver })
        XCTAssertTrue(runtime.start(until:18,canStart:true))
        driver.didStart?()
        runtime.continueThroughVolume(until:14)
        XCTAssertEqual(runtime.deadline,14)
        runtime.stop()
        runtime.stop()
        XCTAssertEqual(driver.invalidations,1)
        XCTAssertFalse(runtime.isRequested)
        XCTAssertFalse(runtime.isRunning)
    }

    @MainActor
    func testDelayedSystemStartAfterDeadlineFailsClosed() async {
        var now = 10.0
        let driver = FakeRuntimeDriver()
        let runtime = InteractionRuntime(clock:{ now },makeDriver:{ driver })
        var interruptions = 0
        runtime.interrupted = { _ in interruptions += 1 }
        XCTAssertTrue(runtime.start(until:18,canStart:true))
        now = 20
        driver.didStart?()
        XCTAssertFalse(runtime.isRequested)
        XCTAssertFalse(runtime.isRunning)
        XCTAssertEqual(interruptions,1)
    }

    @MainActor
    func testSystemInvalidationDuringVolumeStopsOnceAndDoesNotRearm() async {
        let driver = FakeRuntimeDriver()
        let runtime = InteractionRuntime(clock:{ 10 },makeDriver:{ driver })
        var interruptions: [String] = []
        runtime.interrupted = { interruptions.append($0) }
        XCTAssertTrue(runtime.start(until:18,canStart:true))
        driver.didStart?()
        runtime.continueThroughVolume(until:100)
        let stopped = driver.didStop
        stopped?("System cancelled runtime")
        stopped?("Late duplicate")
        XCTAssertFalse(runtime.isRequested)
        XCTAssertEqual(driver.starts,1)
        XCTAssertEqual(interruptions,["System cancelled runtime"])
    }

    @MainActor
    func testLateVolumeEntryCannotReviveAnExpiredArmedWindow() async {
        var now = 10.0
        let driver = FakeRuntimeDriver()
        let runtime = InteractionRuntime(clock:{ now },makeDriver:{ driver })
        XCTAssertTrue(runtime.start(until:18,canStart:true))
        now = 18
        XCTAssertFalse(runtime.continueThroughVolume(until:100))
        XCTAssertFalse(runtime.isRequested)
        XCTAssertNil(runtime.deadline)
        XCTAssertEqual(driver.starts,1)
        XCTAssertEqual(driver.invalidations,1)
    }
}
