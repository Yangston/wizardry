import XCTest
@testable import GestureCore

final class VolumePipelineTests: XCTestCase {
    private final class Simulation {
        enum Event {
            case arrival(VolumeRequest)
            case output(UUID, VolumeRequest)
            case reply(UUID, VolumeReply)
        }
        var client = LiveVolumeScheduler()
        var phone = VolumeCommandCoordinator()
        let configuration = WizardryConfiguration()
        let roundTrip: Double
        var now = 0.0
        var events: [(Double, Event)] = []
        var applied: [(time: Double, age: Double)] = []
        var outputs = 0
        var replies: [UUID: UUID] = [:]

        init(roundTrip: Double) {
            self.roundTrip = roundTrip
            client.begin(revision:configuration.revision)
        }
        func consume(_ effects: [VolumeCommandCoordinator.Effect]) {
            for effect in effects {
                switch effect {
                case let .execute(ticket,request,_):
                    outputs += 1
                    XCTAssertEqual(outputs,1,"Physical writes must remain serialized")
                    events.append((now+0.010,.output(ticket,request)))
                case let .reply(ticket,request,result):
                    guard let requestID = replies.removeValue(forKey:ticket) else { return XCTFail("Missing reply ticket") }
                    // Unequal reply delay exercises out-of-order delivery too.
                    let jitter = request.sequence % 3 == 0 ? 0.015 : -0.004
                    events.append((now+roundTrip/2+jitter,.reply(requestID,result)))
                }
            }
        }
        func tick(_ time: Double) {
            now = time
            while let index = events.indices.filter({events[$0].0 <= now}).min(by:{events[$0].0 < events[$1].0}) {
                let event = events.remove(at:index).1
                switch event {
                case .arrival(let request):
                    let ticket = UUID(); replies[ticket] = request.id
                    consume(phone.receive(request,ticket:ticket,configuration:configuration,now:100+now))
                case let .output(ticket,request):
                    outputs -= 1
                    if request.operation == .update, now >= 0.3, now <= 4.8 {
                        applied.append((now,100+now-request.createdAt))
                    }
                    consume(phone.complete(ticket:ticket,result:.init(outcome:.executed,message:"Readback",
                        sessionID:request.sessionID,sequence:request.sequence,volume:request.target ?? 0.2),now:100+now))
                case let .reply(requestID,result):
                    _ = client.receive(result,requestID:requestID,at:now)
                }
            }
            if Int((now*1000).rounded()) % 10 == 0 { client.setTarget(0.2+0.1*now) }
            if let request = client.nextRequest(at:now,wallTime:100+now) {
                events.append((now+roundTrip/2,.arrival(request)))
            }
            XCTAssertLessThanOrEqual(client.outstandingUpdates,4)
            XCTAssertNotEqual(client.phase,.failed)
        }
    }

    func testAppliedCadenceAcrossClientAndSerializedOutputWithRadioDelay() {
        // An end-to-end synthetic model, not a claim about physical audio or
        // WatchConnectivity. Output service time is 10 ms; capture is 100 Hz.
        for roundTrip in [0.02,0.06,0.10] {
            let simulation = Simulation(roundTrip:roundTrip)
            for millisecond in 0...5000 { simulation.tick(Double(millisecond)/1000) }
            XCTAssertGreaterThanOrEqual(Double(simulation.applied.count)/4.5,30)
            let times = simulation.applied.map(\.time)
            let gaps = zip(times.dropFirst(),times).map {$0.0-$0.1}.sorted()
            XCTAssertFalse(gaps.isEmpty)
            if !gaps.isEmpty { XCTAssertLessThanOrEqual(gaps[Int(Double(gaps.count-1)*0.95)],0.060001) }
            XCTAssertLessThanOrEqual(simulation.applied.map(\.age).max() ?? .infinity,0.150001)
        }
    }
}
