import Foundation

/// Bounded latest-target scheduling. Callers supply clocks and deliver replies,
/// so deterministic tests exercise the same state machine as WatchConnectivity.
struct LiveVolumeScheduler {
    enum Phase: Equatable { case idle, beginning, adjusting, closing, ended, failed }
    enum Reception: Equatable { case ignored, accepted, began, ended, failed }
    struct Statistics {
        var updatesSent = 0
        var appliedReplies = 0
        var supersededReplies = 0
        var maximumOutstandingUpdates = 0
        var lastRoundTrip = 0.0
    }
    private struct Pending {
        var request: VolumeRequest
        var sentAt: Double
        var deadline: Double { sentAt + LiveVolumeScheduler.replyTimeout }
    }
    static let updateInterval = 0.02
    static let maximumUpdates = 4
    static let replyTimeout = 1.3
    private(set) var phase = Phase.idle
    private(set) var latestTarget: Double?
    private(set) var acknowledged: Double?
    private(set) var dryRun = false
    private(set) var failureMessage: String?
    private(set) var statistics = Statistics()
    private var sessionID: UUID?
    private var revision = ""
    private var profileID: String?
    private var sequence = 0
    private var appliedSequence = -1
    private var pending: [UUID:Pending] = [:]
    private var beginSent = false
    private var beginAcknowledged = false
    private var endSent = false
    private var lastSend = -Double.infinity
    private var sentTarget: Double?
    private var appliedTimes: [Double] = []

    var outstandingUpdates: Int { pending.values.filter { $0.request.operation == .update }.count }
    var outstandingRequests: Int { pending.count }
    func confirmedRate(at now: Double) -> Double {
        let recent = appliedTimes.filter { now-$0 <= 2 }
        guard let first = recent.first, let last = recent.last, last > first else { return 0 }
        return Double(recent.count-1)/max(last-first,now-first)
    }

    mutating func begin(revision: String, sessionID: UUID = UUID(), profileID: String? = nil) {
        self = Self()
        self.revision = revision; self.sessionID = sessionID; phase = .beginning
        self.profileID = profileID
    }

    mutating func setTarget(_ value: Double) {
        guard phase == .adjusting, value.isFinite else { return }
        latestTarget = min(1,max(0,value))
    }

    mutating func finish() {
        guard phase == .beginning || phase == .adjusting else { return }
        // Freeze the target. End has its own slot; the phone serializes its write.
        phase = .closing
    }

    mutating func expire(at now: Double) {
        guard [.beginning,.adjusting,.closing].contains(phase) else { return }
        if relevantPending.contains(where: { now >= $0.deadline }) {
            fail("Volume reply timed out · stopped, unconfirmed")
        }
    }

    mutating func nextRequest(at now: Double, wallTime: Double) -> VolumeRequest? {
        guard now.isFinite, wallTime.isFinite else {
            fail("Invalid volume clock · stopped, unconfirmed"); return nil
        }
        expire(at:now)
        guard let sessionID else { return nil }
        let operation: VolumeRequest.Operation
        if !beginSent, phase == .beginning || phase == .closing {
            operation = .begin; beginSent = true
        } else if phase == .closing, beginAcknowledged, !endSent, latestTarget != nil {
            operation = .end; endSent = true
        } else if phase == .adjusting, latestTarget != nil,
                  outstandingUpdates < Self.maximumUpdates,
                  now + 0.000000001 >= nextUpdateTime {
            operation = .update
        } else { return nil }
        if operation != .begin { sequence += 1 }
        let request = VolumeRequest(sessionID:sessionID,revision:revision,sequence:sequence,
                                    createdAt:wallTime,operation:operation,
                                    target:operation == .begin ? nil : latestTarget,profileID:profileID)
        pending[request.id] = .init(request:request,sentAt:now)
        lastSend = now
        if operation != .begin { sentTarget = latestTarget }
        if operation == .update {
            statistics.updatesSent += 1
            statistics.maximumOutstandingUpdates = max(statistics.maximumOutstandingUpdates,outstandingUpdates)
        }
        return request
    }

    /// A full window sleeps until a reply releases a slot; it never queues targets.
    func nextWake(at now: Double) -> Double? {
        guard [.beginning,.adjusting,.closing].contains(phase) else { return nil }
        var deadlines = relevantPending.map(\.deadline)
        if !beginSent || (phase == .closing && beginAcknowledged && !endSent) { deadlines.append(now) }
        if phase == .adjusting, latestTarget != nil, outstandingUpdates < Self.maximumUpdates {
            deadlines.append(nextUpdateTime)
        }
        return deadlines.min().map { max(now,$0) }
    }

    mutating func receive(_ reply: VolumeReply, requestID: UUID, at now: Double) -> Reception {
        guard let delivery = pending[requestID] else { return .ignored }
        let request = delivery.request
        // Closing has its own deadline. Obsolete update failures/timeouts cannot
        // undo a final write that the phone is confirming.
        if phase == .closing, request.operation == .update {
            pending.removeValue(forKey:requestID); return .ignored
        }
        expire(at:now)
        guard phase != .failed else { return .failed }
        pending.removeValue(forKey:requestID)
        guard reply.sessionID == request.sessionID, reply.sequence == request.sequence,
              reply.outcome == .executed || reply.outcome == .dryRun else {
            fail("Stopped, unconfirmed · " + reply.message); return .failed
        }
        statistics.lastRoundTrip = max(0,now-delivery.sentAt)
        if reply.disposition == .superseded {
            guard request.operation == .update, reply.volume == nil else {
                fail("Invalid superseded volume reply · stopped, unconfirmed"); return .failed
            }
            statistics.supersededReplies += 1
            return .accepted
        }
        guard let value = reply.volume, value.isFinite, (0...1).contains(value) else {
            fail("Invalid volume acknowledgement · stopped, unconfirmed"); return .failed
        }
        if request.operation == .begin, (reply.transportVersion ?? 0) < 2 {
            fail("Update the iPhone app for smooth live volume, then activate again"); return .failed
        }
        if request.sequence > appliedSequence {
            appliedSequence = request.sequence; acknowledged = value; dryRun = reply.outcome == .dryRun
            if request.operation == .update {
                statistics.appliedReplies += 1
                appliedTimes = appliedTimes.filter { now-$0 <= 2 }; appliedTimes.append(now)
            }
        }
        switch request.operation {
        case .begin:
            beginAcknowledged = true; latestTarget = value; sentTarget = value
            if phase != .closing { phase = .adjusting }
            return .began
        case .update:
            return .accepted
        case .end:
            phase = .ended; pending.removeAll(); sessionID = nil
            return .ended
        }
    }

    private var nextUpdateTime: Double {
        let changed = latestTarget.map { target in sentTarget.map { abs($0-target) >= 0.001 } ?? true } ?? false
        return lastSend + (changed ? Self.updateInterval : 1)
    }
    private var relevantPending: [Pending] {
        pending.values.filter { phase != .closing || $0.request.operation != .update }
    }
    private mutating func fail(_ message: String) {
        phase = .failed; failureMessage = message; pending.removeAll(); sessionID = nil
        latestTarget = acknowledged
    }
}
