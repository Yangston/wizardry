import Combine
import Foundation

/// A bounded window removes round-trip latency from each update's critical path.
/// Only the newest target waits locally; failed commands are never retried.
@MainActor
final class LiveVolumeRemote: ObservableObject {
    enum State: String { case idle, beginning, adjusting, locking, locked, ended, failed }
    @Published private(set) var state = State.idle
    @Published private(set) var requested: Double?
    @Published private(set) var acknowledged: Double?
    @Published private(set) var message = "Live twist volume"
    @Published private(set) var dryRun = false
    var didBegin: (() -> Void)?
    var didFinish: (() -> Void)?
    private let link: WatchLink
    private var scheduler = LiveVolumeScheduler()
    private var lastDisplay = -Double.infinity
    private var lockRequested = false
    private var wakeTask: Task<Void,Never>?
    private var scheduledWake: Double?
    var ownsMotion: Bool { [.beginning,.adjusting,.locking].contains(state) }
    var confirmedUpdateHz: Double { scheduler.confirmedRate(at:ProcessInfo.processInfo.systemUptime) }
    var roundTripMilliseconds: Double { scheduler.statistics.lastRoundTrip*1000 }
    var outstandingUpdateCount: Int { scheduler.outstandingUpdates }

    init(link: WatchLink) { self.link = link }

    func begin(revision: String, phone: Bool = false) {
        guard !ownsMotion else { return }
        cancelWake()
        scheduler.begin(revision:revision,profileID:phone ? "phone" : "computer")
        requested = nil; acknowledged = nil; dryRun = false; lockRequested = false
        lastDisplay = -.infinity
        state = .beginning; message = phone ? "Reading iPhone volume…" : "Reading computer volume…"
        pump()
    }

    func setTarget(_ value: Double) {
        guard state == .adjusting else { return }
        scheduler.setTarget(value)
        pump()
    }

    func finish(lock: Bool) {
        guard state == .beginning || state == .adjusting else { return }
        scheduler.finish(); lockRequested = lock; requested = scheduler.latestTarget
        state = .locking; message = lock ? "Locking…" : "Stopping…"
        pump()
    }

    private func pump() {
        let now = ProcessInfo.processInfo.systemUptime
        scheduler.expire(at:now)
        if showFailureIfNeeded() { return }
        if now-lastDisplay >= 0.05, requested != scheduler.latestTarget {
            requested = scheduler.latestTarget; lastDisplay = now
        }
        if let request = scheduler.nextRequest(at:now,wallTime:Date().timeIntervalSince1970) {
            link.sendVolume(request) { [weak self] reply in
                guard let self else { return }
                let reception = self.scheduler.receive(reply,requestID:request.id,at:ProcessInfo.processInfo.systemUptime)
                if self.showFailureIfNeeded() { return }
                switch reception {
                case .ignored: return
                case .failed: return
                case .accepted:
                    self.publishAcknowledgement()
                case .began:
                    self.publishAcknowledgement()
                    self.requested = self.scheduler.latestTarget
                    self.lastDisplay = ProcessInfo.processInfo.systemUptime
                    if self.scheduler.phase == .adjusting {
                        self.state = .adjusting; self.message = "Twist + / − · lock when ready"
                        self.didBegin?()
                    }
                case .ended:
                    self.publishAcknowledgement()
                    self.state = self.lockRequested ? .locked : .ended
                    self.message = self.lockRequested ? "Locked · activate again" : "Stopped · activate again"
                    self.cancelWake(); self.didFinish?(); return
                }
                self.pump()
            }
        }
        if showFailureIfNeeded() { return }
        scheduleWake()
    }

    private func publishAcknowledgement() {
        if acknowledged != scheduler.acknowledged { acknowledged = scheduler.acknowledged }
        if dryRun != scheduler.dryRun { dryRun = scheduler.dryRun }
    }

    @discardableResult
    private func showFailureIfNeeded() -> Bool {
        guard scheduler.phase == .failed else { return false }
        if state != .failed {
            cancelWake(); requested = scheduler.acknowledged; state = .failed
            message = scheduler.failureMessage ?? "Volume stopped, unconfirmed"
            didFinish?()
        }
        return true
    }

    private func scheduleWake() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let deadline = scheduler.nextWake(at:now) else { cancelWake(); return }
        if let scheduledWake, abs(scheduledWake-deadline) < 0.0001 { return }
        cancelWake(); scheduledWake = deadline
        wakeTask = Task { [weak self] in
            do { try await Task.sleep(for:.seconds(max(0,deadline-ProcessInfo.processInfo.systemUptime))) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            self.wakeTask = nil; self.scheduledWake = nil
            self.pump()
        }
    }

    private func cancelWake() {
        wakeTask?.cancel(); wakeTask = nil; scheduledWake = nil
    }
}
