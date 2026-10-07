import XCTest
@testable import GestureCore

final class VolumeCommandCoordinatorTests: XCTestCase {
    private final class Harness {
        var coordinator = VolumeCommandCoordinator()
        var configuration = WizardryConfiguration()
        var sessionID = UUID()
        var now = 100.0
        var executions: [(UUID, VolumeRequest, String)] = []
        var running: Set<UUID> = []
        var replies: [UUID: VolumeReply] = [:]
        var replyCounts: [UUID: Int] = [:]
        func request(_ operation: VolumeRequest.Operation, _ sequence: Int, target: Double = 0.6) -> VolumeRequest {
            .init(sessionID:sessionID,revision:configuration.revision,sequence:sequence,createdAt:now,
                  operation:operation,target:operation == .begin ? nil : target)
        }
        @discardableResult func submit(_ request: VolumeRequest) -> UUID {
            let ticket = UUID()
            consume(coordinator.receive(request,ticket:ticket,configuration:configuration,now:now))
            return ticket
        }
        func consume(_ effects: [VolumeCommandCoordinator.Effect]) {
            for effect in effects {
                switch effect {
                case let .execute(ticket,request,profileID):
                    XCTAssertTrue(running.isEmpty,"Output writes must never overlap")
                    running.insert(ticket)
                    executions.append((ticket,request,profileID))
                case let .reply(ticket,_,result):
                    replies[ticket] = result
                    replyCounts[ticket,default:0] += 1
                    XCTAssertEqual(replyCounts[ticket],1,"Every request replies exactly once")
                }
            }
        }
        func complete(_ ticket: UUID, outcome: ActionResult.Outcome = .executed, volume: Double = 0.6) {
            guard let request = executions.first(where:{$0.0 == ticket})?.1 else { return XCTFail("No execution to complete") }
            running.remove(ticket)
            let reply = VolumeReply(outcome:outcome,message:"Fake output",sessionID:request.sessionID,
                                    sequence:request.sequence,volume:outcome == .failed ? nil : volume)
            consume(coordinator.complete(ticket:ticket,result:reply,now:now))
        }
        @discardableResult func begin(outcome: ActionResult.Outcome = .executed) -> UUID {
            let ticket = submit(request(.begin,0))
            complete(ticket,outcome:outcome,volume:0.4)
            return ticket
        }
    }

    func testBeginIsABarrierAndAdvertisesNewTransport() {
        let h = Harness()
        let begin = h.submit(h.request(.begin,0))
        let premature = h.submit(h.request(.update,1))
        XCTAssertEqual(h.replies[premature]?.outcome,.failed)
        XCTAssertEqual(h.executions.count,1)
        h.complete(begin,volume:0.4)
        XCTAssertEqual(h.replies[begin]?.transportVersion,2)
        XCTAssertEqual(h.replies[begin]?.disposition,.applied)
        XCTAssertEqual(h.replies[begin]?.volume,0.4)
        XCTAssertFalse(h.coordinator.isBusy)
        XCTAssertTrue(h.coordinator.hasSession)
    }

    func testOnlyNewestWaitingTargetExecutesAndOlderArrivalIsSuperseded() {
        let h = Harness(); h.begin()
        let first = h.submit(h.request(.update,1,target:0.5))
        let second = h.submit(h.request(.update,2,target:0.55))
        let newest = h.submit(h.request(.update,4,target:0.7))
        let reordered = h.submit(h.request(.update,3,target:0.6))
        for ticket in [second,reordered] {
            XCTAssertEqual(h.replies[ticket]?.disposition,.superseded)
            XCTAssertEqual(h.replies[ticket]?.outcome,.executed)
            XCTAssertNil(h.replies[ticket]?.volume)
        }
        XCTAssertEqual(h.executions.count,2)
        h.complete(first,volume:0.5)
        XCTAssertEqual(h.executions.last?.0,newest)
        XCTAssertEqual(h.executions.last?.1.target,0.7)
        h.complete(newest,volume:0.7)
        XCTAssertFalse(h.coordinator.isBusy)
        XCTAssertEqual(h.executions.map{$0.1.sequence},[0,1,4])
    }

    func testEndClosesAdmissionDiscardsPendingAndWaitsForCurrentWrite() {
        let h = Harness(); h.begin()
        let first = h.submit(h.request(.update,1,target:0.5))
        let pending = h.submit(h.request(.update,2,target:0.6))
        let endRequest = h.request(.end,3,target:0.65)
        let end = h.submit(endRequest)
        XCTAssertEqual(h.replies[pending]?.disposition,.superseded)
        XCTAssertNil(h.replies[end])
        let late = h.submit(h.request(.update,4,target:0.8))
        XCTAssertEqual(h.replies[late]?.outcome,.failed)
        XCTAssertEqual(h.executions.map{$0.1.sequence},[0,1])
        h.complete(first,volume:0.5)
        XCTAssertEqual(h.executions.last?.0,end)
        XCTAssertEqual(h.executions.last?.1.target,0.65)
        h.complete(end,volume:0.65)
        XCTAssertEqual(h.replies[end]?.disposition,.applied)
        XCTAssertEqual(h.replies[end]?.volume,0.65)
        XCTAssertFalse(h.coordinator.hasSession)
        let duplicate = h.submit(endRequest)
        XCTAssertEqual(h.replies[duplicate]?.outcome,.failed)
        let reopened = h.submit(h.request(.begin,0))
        XCTAssertEqual(h.replies[reopened]?.outcome,.failed)
        XCTAssertEqual(h.executions.map{$0.1.sequence},[0,1,3])
    }

    func testFailedExecutingWriteAbortsPendingLockWithoutRetry() {
        let h = Harness(); h.begin()
        let first = h.submit(h.request(.update,1))
        let end = h.submit(h.request(.end,2))
        h.complete(first,outcome:.failed)
        XCTAssertEqual(h.replies[first]?.outcome,.failed)
        XCTAssertEqual(h.replies[end]?.outcome,.failed)
        XCTAssertEqual(h.executions.map{$0.1.sequence},[0,1])
        XCTAssertFalse(h.coordinator.isBusy)
        XCTAssertFalse(h.coordinator.hasSession)
        let continued = h.submit(h.request(.update,3))
        XCTAssertEqual(h.replies[continued]?.outcome,.failed)
    }

    func testExpiryIsCheckedBeforeStartingWaitingIO() {
        let h = Harness(); h.begin()
        let first = h.submit(h.request(.update,1))
        var delayed = h.request(.update,2)
        delayed.createdAt = 99.8
        let pending = h.submit(delayed)
        h.now = 100.81
        h.complete(first)
        XCTAssertEqual(h.replies[first]?.outcome,.executed)
        XCTAssertEqual(h.replies[pending]?.outcome,.failed)
        XCTAssertEqual(h.executions.map{$0.1.sequence},[0,1])
        XCTAssertFalse(h.coordinator.hasSession)
        let expired = h.submit(delayed)
        XCTAssertEqual(h.replies[expired]?.outcome,.failed)
    }

    func testInvalidationRetiresOldWriteBeforeNewBaselineAndIsolatesLateCompletion() {
        let h = Harness(); h.begin()
        let first = h.submit(h.request(.update,1))
        let pending = h.submit(h.request(.update,2))
        h.consume(h.coordinator.invalidate(now:h.now,message:"Output route changed"))
        XCTAssertEqual(h.replies[first]?.outcome,.failed)
        XCTAssertEqual(h.replies[pending]?.outcome,.failed)
        XCTAssertFalse(h.coordinator.isCurrentExecution(first))
        XCTAssertTrue(h.coordinator.isBusy) // Physical I/O is still retiring.
        h.sessionID = UUID()
        let begin = h.submit(h.request(.begin,0))
        XCTAssertEqual(h.executions.count,2)
        h.complete(first)
        XCTAssertEqual(h.executions.last?.0,begin)
        XCTAssertTrue(h.coordinator.isCurrentExecution(begin))
        h.complete(first,outcome:.failed) // Repeated stale callback cannot touch new session.
        XCTAssertTrue(h.coordinator.isCurrentExecution(begin))
        h.complete(begin,volume:0.7)
        XCTAssertEqual(h.replies[begin]?.volume,0.7)
        XCTAssertTrue(h.coordinator.hasSession)
    }

    func testNewSessionReplacesWaitingWorkWithoutOverlappingOutput() {
        let h = Harness(); h.begin()
        let first = h.submit(h.request(.update,1))
        let pending = h.submit(h.request(.update,2))
        h.sessionID = UUID()
        let begin = h.submit(h.request(.begin,0))
        XCTAssertEqual(h.replies[first]?.outcome,.failed)
        XCTAssertEqual(h.replies[pending]?.outcome,.failed)
        XCTAssertNil(h.replies[begin])
        h.complete(first,outcome:.failed)
        XCTAssertEqual(h.executions.last?.0,begin)
        h.complete(begin)
        XCTAssertTrue(h.coordinator.hasSession)
    }

    func testProfileAndRevisionChangeInvalidateCurrentGeneration() {
        let h = Harness(); h.begin()
        let first = h.submit(h.request(.update,1))
        h.configuration.selectedProfileID = "phone"
        h.configuration.revision = UUID().uuidString
        h.sessionID = UUID()
        let begin = h.submit(h.request(.begin,0))
        XCTAssertEqual(h.replies[first]?.outcome,.failed)
        h.complete(first)
        XCTAssertEqual(h.executions.last?.2,"phone")
        h.complete(begin)
        let update = h.submit(h.request(.update,1))
        XCTAssertEqual(h.executions.last?.0,update)
    }

    func testDryRunSupersededReplyDoesNotClaimAppliedVolume() {
        let h = Harness(); h.begin(outcome:.dryRun)
        let first = h.submit(h.request(.update,1))
        let pending = h.submit(h.request(.update,2))
        _ = h.submit(h.request(.update,3))
        XCTAssertEqual(h.replies[pending]?.outcome,.dryRun)
        XCTAssertEqual(h.replies[pending]?.disposition,.superseded)
        XCTAssertNil(h.replies[pending]?.volume)
        h.complete(first,outcome:.dryRun)
    }

    func testMalformedAcknowledgementFailsSessionAndPendingWork() {
        let h = Harness(); h.begin()
        let first = h.submit(h.request(.update,1))
        let pending = h.submit(h.request(.update,2))
        h.complete(first,volume:.nan)
        XCTAssertEqual(h.replies[first]?.outcome,.failed)
        XCTAssertEqual(h.replies[pending]?.outcome,.failed)
        XCTAssertFalse(h.coordinator.hasSession)
    }

    func testExpiredRetiredBeginNeverRunsAndOldSessionsCannotReopen() {
        let h = Harness(); h.begin()
        let first = h.submit(h.request(.update,1))
        let oldSession = h.sessionID
        h.sessionID = UUID()
        let begin = h.submit(h.request(.begin,0))
        h.now += 1.01
        h.complete(first)
        XCTAssertEqual(h.replies[begin]?.outcome,.failed)
        XCTAssertEqual(h.executions.count,2)
        h.sessionID = oldSession
        let reopened = h.submit(h.request(.begin,0))
        XCTAssertEqual(h.replies[reopened]?.outcome,.failed)
    }

    func testDuplicateAndOutOfOrderLockDoNotReplacePendingValue() {
        let h = Harness(); h.begin()
        let request = h.request(.update,2)
        let update = h.submit(request)
        let duplicate = h.submit(request)
        let oldEnd = h.submit(h.request(.end,1))
        XCTAssertEqual(h.replies[duplicate]?.outcome,.failed)
        XCTAssertEqual(h.replies[oldEnd]?.outcome,.failed)
        XCTAssertTrue(h.coordinator.isCurrentExecution(update))
        h.complete(update)
        XCTAssertTrue(h.coordinator.hasSession)
    }
}
