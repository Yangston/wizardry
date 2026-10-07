import Foundation
import XCTest
@testable import GestureCore

final class LiveVolumeSchedulerTests: XCTestCase {
    private func reply(_ request: VolumeRequest, volume: Double? = nil,
                       superseded: Bool = false, version: Int? = 2) -> VolumeReply {
        var result = VolumeReply(outcome:.executed,message:"test",sessionID:request.sessionID,
                                 sequence:request.sequence,volume:superseded ? nil : (volume ?? request.target ?? 0.5))
        result.transportVersion = version
        result.disposition = superseded ? .superseded : .applied
        return result
    }
    private func request(_ scheduler: inout LiveVolumeScheduler, at time: Double,
                         file: StaticString = #filePath, line: UInt = #line) throws -> VolumeRequest {
        try XCTUnwrap(scheduler.nextRequest(at:time,wallTime:100+time),file:file,line:line)
    }
    private func started() throws -> LiveVolumeScheduler {
        var scheduler = LiveVolumeScheduler()
        scheduler.begin(revision:"revision")
        let begin = try request(&scheduler,at:0)
        XCTAssertEqual(scheduler.receive(reply(begin),requestID:begin.id,at:0.001),.began)
        return scheduler
    }

    func testBeginBarrierAndRequiredCapability() throws {
        var scheduler = LiveVolumeScheduler()
        scheduler.begin(revision:"revision")
        let begin = try request(&scheduler,at:0)
        scheduler.setTarget(0.8)
        XCTAssertNil(scheduler.nextRequest(at:0.5,wallTime:100.5))
        XCTAssertNil(scheduler.latestTarget)
        XCTAssertEqual(begin.sequence,0)
        XCTAssertTrue(begin.isValid)
        XCTAssertEqual(scheduler.receive(reply(begin,version:nil),requestID:begin.id,at:0.6),.failed)
        XCTAssertTrue(scheduler.failureMessage?.contains("Update the iPhone app") == true)
        XCTAssertNil(scheduler.nextRequest(at:0.7,wallTime:100.7))
    }

    func testFiftyHzStartsDoNotWaitAnotherIntervalAfterReply() throws {
        var scheduler = try started()
        scheduler.setTarget(0.6)
        XCTAssertNil(scheduler.nextRequest(at:0.019,wallTime:100.019))
        let first = try request(&scheduler,at:0.02)
        scheduler.setTarget(0.7)
        let second = try request(&scheduler,at:0.04)
        XCTAssertEqual(scheduler.outstandingUpdates,2)
        XCTAssertEqual(scheduler.receive(reply(first),requestID:first.id,at:0.071),.accepted)
        scheduler.setTarget(0.8)
        let third = try request(&scheduler,at:0.071)
        XCTAssertEqual([first.sequence,second.sequence,third.sequence],[1,2,3])
        XCTAssertEqual(third.target,0.8)
        XCTAssertEqual(third.createdAt,100.071,accuracy:0.000001)
        XCTAssertNil(scheduler.nextRequest(at:0.072,wallTime:100.072))
    }

    func testFullWindowKeepsOnlyNewestUnsentTargetAndSupersededReleasesSlot() throws {
        var scheduler = try started()
        var sent: [VolumeRequest] = []
        for i in 1...4 {
            scheduler.setTarget(0.5+Double(i)*0.02)
            sent.append(try request(&scheduler,at:Double(i)*0.02))
        }
        for i in 9...20 {
            scheduler.setTarget(Double(i)/25)
            XCTAssertNil(scheduler.nextRequest(at:Double(i)*0.01,wallTime:100+Double(i)*0.01))
        }
        XCTAssertEqual(scheduler.outstandingUpdates,4)
        XCTAssertEqual(scheduler.receive(reply(sent[0],superseded:true),requestID:sent[0].id,at:0.201),.accepted)
        XCTAssertEqual(scheduler.acknowledged,0.5)
        let latest = try request(&scheduler,at:0.201)
        XCTAssertEqual(latest.target,0.8)
        XCTAssertEqual(latest.sequence,5)
        XCTAssertEqual(scheduler.statistics.maximumOutstandingUpdates,4)
        XCTAssertEqual(scheduler.statistics.supersededReplies,1)
    }

    func testReorderedAppliedRepliesCannotRegressAcknowledgement() throws {
        var scheduler = try started()
        scheduler.setTarget(0.6)
        let first = try request(&scheduler,at:0.02)
        scheduler.setTarget(0.7)
        let second = try request(&scheduler,at:0.04)
        XCTAssertEqual(scheduler.receive(reply(second),requestID:second.id,at:0.08),.accepted)
        XCTAssertEqual(scheduler.receive(reply(first),requestID:first.id,at:0.09),.accepted)
        XCTAssertEqual(scheduler.acknowledged,0.7)
        XCTAssertEqual(scheduler.outstandingUpdates,0)
        XCTAssertEqual(scheduler.receive(reply(first),requestID:first.id,at:0.10),.ignored)
    }

    func testEndBypassesFullWindowFreezesTargetAndIgnoresOldFailuresAndTimeouts() throws {
        var scheduler = try started()
        var sent: [VolumeRequest] = []
        for i in 1...4 {
            scheduler.setTarget(0.5+Double(i)*0.02)
            sent.append(try request(&scheduler,at:Double(i)*0.02))
        }
        scheduler.setTarget(0.9); scheduler.finish(); scheduler.setTarget(0.1)
        let end = try request(&scheduler,at:0.081)
        XCTAssertEqual(end.operation,.end)
        XCTAssertEqual(end.sequence,5)
        XCTAssertEqual(end.target,0.9)
        XCTAssertEqual(scheduler.outstandingRequests,5)
        XCTAssertEqual(scheduler.receive(.failure("old update failed",request:sent[0]),requestID:sent[0].id,at:0.1),.ignored)
        scheduler.expire(at:1.36) // Remaining updates expired; end has not.
        XCTAssertEqual(scheduler.phase,.closing)
        XCTAssertNil(scheduler.nextRequest(at:1.36,wallTime:101.36))
        XCTAssertEqual(scheduler.receive(reply(end),requestID:end.id,at:1.37),.ended)
        XCTAssertEqual(scheduler.acknowledged,0.9)
        XCTAssertEqual(scheduler.outstandingRequests,0)
        XCTAssertNil(scheduler.nextWake(at:1.37))
    }

    func testFinishDuringBeginWaitsForBaselineThenSendsOnlyEnd() throws {
        var scheduler = LiveVolumeScheduler()
        scheduler.begin(revision:"revision")
        let begin = try request(&scheduler,at:0)
        scheduler.finish()
        XCTAssertNil(scheduler.nextRequest(at:0.01,wallTime:100.01))
        XCTAssertEqual(scheduler.receive(reply(begin,volume:0.37),requestID:begin.id,at:0.02),.began)
        let end = try request(&scheduler,at:0.02)
        XCTAssertEqual(end.operation,.end)
        XCTAssertEqual(end.target,0.37)
        XCTAssertEqual(scheduler.statistics.updatesSent,0)
    }

    func testExpiryAndFailureDiscardAllWorkWithoutRetry() throws {
        for closing in [false,true] {
            var scheduler = try started()
            scheduler.setTarget(0.9)
            if closing { scheduler.finish() }
            let sent = try request(&scheduler,at:0.02)
            scheduler.expire(at:1.321)
            XCTAssertEqual(scheduler.phase,.failed)
            XCTAssertEqual(scheduler.outstandingRequests,0)
            XCTAssertEqual(scheduler.latestTarget,0.5)
            XCTAssertEqual(scheduler.receive(reply(sent),requestID:sent.id,at:1.4),.ignored)
            XCTAssertNil(scheduler.nextRequest(at:2,wallTime:102))
            XCTAssertNil(scheduler.nextWake(at:2))
        }
        var scheduler = try started()
        scheduler.setTarget(0.9)
        let sent = try request(&scheduler,at:0.02)
        XCTAssertEqual(scheduler.receive(.failure("receiver offline",request:sent),requestID:sent.id,at:0.03),.failed)
        XCTAssertNil(scheduler.nextRequest(at:0.04,wallTime:100.04))
    }

    func testFreshGenerationIgnoresOldCallbacksAndDeadlines() throws {
        var scheduler = try started()
        scheduler.setTarget(0.9)
        let old = try request(&scheduler,at:0.02)
        scheduler.begin(revision:"new revision")
        let begin = try request(&scheduler,at:1)
        XCTAssertNotEqual(begin.sessionID,old.sessionID)
        XCTAssertEqual(scheduler.receive(reply(begin,volume:0.3),requestID:begin.id,at:1.01),.began)
        XCTAssertEqual(scheduler.receive(.failure("late old failure",request:old),requestID:old.id,at:1.4),.ignored)
        scheduler.expire(at:1.5)
        XCTAssertEqual(scheduler.phase,.adjusting)
        XCTAssertEqual(scheduler.acknowledged,0.3)
    }

    func testHeartbeatsAndDeadlineDrivenWake() throws {
        var scheduler = try started()
        XCTAssertEqual(try XCTUnwrap(scheduler.nextWake(at:0.001)),1,accuracy:0.000001)
        XCTAssertNil(scheduler.nextRequest(at:0.99,wallTime:100.99))
        let heartbeat = try request(&scheduler,at:1)
        XCTAssertEqual(heartbeat.target,0.5)
        XCTAssertEqual(scheduler.receive(reply(heartbeat),requestID:heartbeat.id,at:1.05),.accepted)
        XCTAssertEqual(try XCTUnwrap(scheduler.nextWake(at:1.05)),2,accuracy:0.000001)
        scheduler.setTarget(0.6)
        XCTAssertEqual(try XCTUnwrap(scheduler.nextWake(at:1.05)),1.05,accuracy:0.000001)
    }

    func testMalformedRepliesCannotAcknowledgeOrKeepSessionAlive() throws {
        for kind in 0...3 {
            var scheduler = try started()
            scheduler.setTarget(0.9)
            let sent = try request(&scheduler,at:0.02)
            var invalid = reply(sent)
            switch kind {
            case 0: invalid.sequence += 1
            case 1: invalid.sessionID = UUID()
            case 2: invalid.volume = .nan
            default: invalid.disposition = .superseded // Must not carry a volume.
            }
            XCTAssertEqual(scheduler.receive(invalid,requestID:sent.id,at:0.03),.failed)
            XCTAssertEqual(scheduler.acknowledged,0.5)
        }
    }

    func testHundredHzTargetsWithRoundTripDelayAndJitterKeepBoundedThirtyHzDispatch() throws {
        // These are transport dispatch metrics, not physical-device readback.
        for roundTrip in [0.02,0.06,0.10] {
            var scheduler = try started()
            var replies: [(Double,VolumeRequest)] = []
            var dispatches: [Double] = []
            for millisecond in 1...5000 {
                let now = Double(millisecond)/1000
                if millisecond % 10 == 0 { scheduler.setTarget(0.25+0.1*now) }
                let ready = replies.filter { $0.0 <= now }.sorted { $0.0 < $1.0 }
                replies.removeAll { $0.0 <= now }
                for (_,sent) in ready {
                    _ = scheduler.receive(reply(sent),requestID:sent.id,at:now)
                }
                if let sent = scheduler.nextRequest(at:now,wallTime:100+now) {
                    let jitter = sent.sequence % 3 == 0 ? 0.015 : -0.005
                    replies.append((now+roundTrip+jitter,sent))
                    if now >= 0.2, now <= 4.8 { dispatches.append(now) }
                }
                XCTAssertLessThanOrEqual(scheduler.outstandingUpdates,4)
                XCTAssertEqual(scheduler.phase,.adjusting)
            }
            XCTAssertGreaterThanOrEqual(Double(dispatches.count)/4.6,30)
            let gaps = zip(dispatches.dropFirst(),dispatches).map { $0.0-$0.1 }.sorted()
            XCTAssertLessThanOrEqual(gaps[Int(Double(gaps.count-1)*0.95)],0.0600001)
        }
    }
}
