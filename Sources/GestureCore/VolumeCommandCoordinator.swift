import Foundation

/// Serial output with one replaceable waiting value. Effects keep I/O and the
/// clock injectable: callers must complete every execution, including retired
/// work, before another output operation can start. Nothing is retried.
struct VolumeCommandCoordinator {
    enum Effect {
        case execute(ticket: UUID, request: VolumeRequest, profileID: String)
        case reply(ticket: UUID, request: VolumeRequest, result: VolumeReply)
    }
    private struct Work {
        let ticket: UUID
        let request: VolumeRequest
        let profileID: String
        let generation: Int
        var replied = false
    }
    private enum Phase { case beginning, ready, closing }
    private struct Session {
        let id: UUID
        let revision: String
        let profileID: String
        var sequence = 0
        var phase = Phase.beginning
        var outcome = ActionResult.Outcome.executed
    }
    private var session: Session?
    private var executing: Work?
    private var waiting: Work?
    private var generation = 0
    private var closed: [UUID: Double] = [:]
    private var seen: [UUID: Double] = [:]
    var isBusy: Bool { executing != nil || waiting != nil }
    var hasSession: Bool { session != nil }

    func isCurrentExecution(_ ticket: UUID) -> Bool {
        executing.map { $0.ticket == ticket && $0.generation == generation && !$0.replied } ?? false
    }

    mutating func receive(_ request: VolumeRequest, ticket: UUID,
                          configuration: WizardryConfiguration, now: Double) -> [Effect] {
        guard now.isFinite else {
            return [reply(ticket,request,.failure("Volume clock unavailable",request:request))]
        }
        closed = closed.filter { now-$0.value < 1800 }
        seen = seen.filter { now-$0.value < 30 }
        var effects: [Effect] = []
        if let session, !configuration.allowsControl || session.revision != configuration.revision || session.profileID != configuration.selectedProfileID {
            effects += invalidate(now:now,message:"Settings changed. Activate again.")
        }
        guard configuration.allowsControl, request.isValid, fresh(request,now:now), request.revision == configuration.revision,
              request.profileID.map({$0 == configuration.selectedProfileID}) ?? true,
              configuration.supportsLiveVolume, seen[request.id] == nil,
              closed[request.sessionID] == nil else {
            return effects + [reply(ticket,request,.failure("Expired, duplicate, or invalid volume session",request:request))]
        }
        if request.operation == .begin {
            guard session?.id != request.sessionID else {
                return effects + [reply(ticket,request,.failure("Volume session already used. Activate again.",request:request))]
            }
            effects += invalidate(now:now,message:"Volume session replaced. Activate again.")
            session = Session(id:request.sessionID,revision:request.revision,profileID:configuration.selectedProfileID)
        } else {
            guard let active = session, active.id == request.sessionID, active.phase == .ready else {
                return effects + [reply(ticket,request,.failure("Volume session is not ready or already closed",request:request))]
            }
            seen[request.id] = now
            if request.sequence <= active.sequence {
                if request.operation == .update {
                    return effects + [reply(ticket,request,superseded(request,outcome:active.outcome))]
                }
                return effects + [reply(ticket,request,.failure("Out-of-order volume lock",request:request))]
            }
            session?.sequence = request.sequence
            if request.operation == .end {
                session?.phase = .closing
                closed[request.sessionID] = now
            }
        }
        seen[request.id] = now
        if let old = waiting {
            effects.append(reply(old.ticket,old.request,superseded(old.request,outcome:session?.outcome ?? .executed)))
        }
        waiting = Work(ticket:ticket,request:request,profileID:configuration.selectedProfileID,generation:generation)
        effects += startNext(now:now)
        return effects
    }

    mutating func complete(ticket: UUID, result: VolumeReply, now: Double) -> [Effect] {
        guard let work = executing, work.ticket == ticket else { return [] }
        executing = nil
        // A settings/route/session change has already failed this callback.
        // Its output is retired before we read a new session's baseline.
        guard work.generation == generation, !work.replied else { return startNext(now:now) }
        var result = result
        if !fresh(work.request,now:now) {
            result = .failure("Volume request expired; not retried. Activate again.",request:work.request)
        } else if result.outcome == .failed {
            result = .failure(result.message,request:work.request)
        } else {
            guard result.sessionID == work.request.sessionID, result.sequence == work.request.sequence,
                  result.outcome == .executed || result.outcome == .dryRun,
                  result.disposition != .superseded,
                  let volume = result.volume, volume.isFinite, (0...1).contains(volume) else {
                return fail(work:work,message:"Invalid volume acknowledgement",now:now)
            }
            result.transportVersion = 2
            result.disposition = .applied
        }
        var effects = [reply(work.ticket,work.request,result)]
        if result.outcome == .failed {
            effects += invalidate(now:now,message:result.message)
        } else if work.request.operation == .begin {
            session?.phase = .ready
            session?.outcome = result.outcome
        } else if work.request.operation == .end {
            session = nil
        }
        effects += startNext(now:now)
        return effects
    }

    mutating func invalidate(now: Double, message: String = "Volume session interrupted. Activate again.") -> [Effect] {
        if let session { closed[session.id] = now }
        session = nil
        generation += 1
        var effects: [Effect] = []
        if let work = waiting {
            effects.append(reply(work.ticket,work.request,.failure(message,request:work.request)))
            waiting = nil
        }
        if var work = executing, !work.replied {
            effects.append(reply(work.ticket,work.request,.failure(message,request:work.request)))
            work.replied = true
            executing = work
        }
        return effects
    }

    private mutating func fail(work: Work, message: String, now: Double) -> [Effect] {
        [reply(work.ticket,work.request,.failure(message,request:work.request))] + invalidate(now:now,message:message)
    }
    private mutating func startNext(now: Double) -> [Effect] {
        guard executing == nil, let work = waiting else { return [] }
        waiting = nil
        guard fresh(work.request,now:now) else {
            return fail(work:work,message:"Waiting volume request expired; not retried. Activate again.",now:now)
        }
        executing = work
        return [.execute(ticket:work.ticket,request:work.request,profileID:work.profileID)]
    }
    private func fresh(_ request: VolumeRequest, now: Double) -> Bool {
        now.isFinite && request.createdAt <= now+0.1 && now < request.createdAt+1
    }
    private func superseded(_ request: VolumeRequest, outcome: ActionResult.Outcome) -> VolumeReply {
        .init(outcome:outcome,message:"Newer volume target retained",sessionID:request.sessionID,
              sequence:request.sequence,volume:nil,transportVersion:2,disposition:.superseded)
    }
    private func reply(_ ticket: UUID, _ request: VolumeRequest, _ result: VolumeReply) -> Effect {
        .reply(ticket:ticket,request:request,result:result)
    }
}
