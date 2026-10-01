import Combine
import Foundation

/// One transport request in flight. Coalescing is bounded to the current, live
/// session; no updates survive failure, final acknowledgement, or timeout.
@MainActor
final class LiveVolumeRemote: ObservableObject {
    enum State: String { case idle, beginning, adjusting, locking, locked, ended, failed }
    @Published private(set) var state = State.idle
    @Published private(set) var requested: Double?
    @Published private(set) var acknowledged: Double?
    @Published private(set) var message = "Experimental height control"
    @Published private(set) var dryRun = false
    var didBegin: (() -> Void)?
    var didFinish: (() -> Void)?
    private let link: WatchLink
    private var sessionID: UUID?
    private var revision = ""
    private var sequence = 0
    private var inFlight: UUID?
    private var lastSend = -Double.infinity
    private var sentTarget: Double?
    private var closing = false
    private var lockRequested = false
    private var loop: Task<Void,Never>?
    private var timeout: Task<Void,Never>?
    var ownsMotion: Bool { [.beginning,.adjusting,.locking].contains(state) }
    init(link: WatchLink) { self.link = link }
    func begin(revision: String) {
        guard !ownsMotion else { return }
        sessionID = UUID(); self.revision = revision; sequence = 0
        requested = nil; acknowledged = nil; sentTarget = nil; closing = false; dryRun = false
        state = .beginning; message = "Reading computer volume…"
        transmit(.begin)
        // An unreachable paired phone can fail synchronously in sendVolume.
        guard ownsMotion else { return }
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.milliseconds(50)) } catch { return }
                self?.pump()
            }
        }
    }
    func setTarget(_ value: Double) {
        guard state == .adjusting, value.isFinite else { return }
        requested = min(1,max(0,value)); pump()
    }
    func finish(lock: Bool) {
        guard state == .beginning || state == .adjusting else { return }
        closing = true; lockRequested = lock; state = .locking
        message = lock ? "Locking…" : "Stopping…"
        pump()
    }
    private func pump() {
        guard inFlight == nil, sessionID != nil else { return }
        if closing, requested != nil { transmit(.end); return }
        guard state == .adjusting, let target = requested else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime-lastSend
        if elapsed >= 0.21 && ((sentTarget.map {abs($0-target) >= 0.002} ?? true) || elapsed >= 1) { transmit(.update) }
    }
    private func transmit(_ operation: VolumeRequest.Operation) {
        guard let sessionID, inFlight == nil else { return }
        if operation != .begin { sequence += 1 }
        let request = VolumeRequest(sessionID:sessionID,revision:revision,sequence:sequence,operation:operation,
                                    target:operation == .begin ? nil : requested)
        inFlight = request.id; lastSend = ProcessInfo.processInfo.systemUptime
        if operation != .begin { sentTarget = requested }
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for:.milliseconds(1300)) } catch { return }
            guard let self, self.inFlight == request.id else { return }
            self.fail("Volume reply timed out · stopped, unconfirmed")
        }
        link.sendVolume(request) { [weak self] reply in
            guard let self, self.inFlight == request.id else { return }
            self.timeout?.cancel(); self.inFlight = nil
            guard reply.sessionID == request.sessionID, reply.sequence == request.sequence,
                  reply.outcome != .failed, let value = reply.volume, value.isFinite, (0...1).contains(value) else {
                self.fail("Stopped, unconfirmed · "+reply.message); return
            }
            self.acknowledged = value; self.dryRun = reply.outcome == .dryRun
            // Space updates from receipt of the previous acknowledgement. This
            // guarantees receiver spacing even when network latency fluctuates.
            self.lastSend = ProcessInfo.processInfo.systemUptime
            switch operation {
            case .begin:
                self.requested = value
                if !self.closing {
                    self.state = .adjusting; self.message = "Raise / lower · lock when ready"
                    self.didBegin?()
                }
            case .update: break
            case .end:
                self.state = self.lockRequested ? .locked : .ended
                self.message = self.lockRequested ? "Locked · activate again" : "Stopped · activate again"
                self.loop?.cancel(); self.sessionID = nil; self.didFinish?()
            }
            self.pump()
        }
    }
    private func fail(_ message: String) {
        timeout?.cancel(); loop?.cancel(); inFlight = nil; sessionID = nil
        requested = acknowledged; closing = false; state = .failed; self.message = message
        didFinish?()
    }
}
