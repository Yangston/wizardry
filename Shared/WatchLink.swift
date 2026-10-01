import Combine
import Foundation
import WatchConnectivity

@MainActor
final class WatchLink: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var reachable = false
    @Published private(set) var status = "Connecting to paired device…"
    var configurationReceived: ((WizardryConfiguration) -> Void)?
    var gestureReceived: ((GestureRequest, @escaping (ActionResult) -> Void) -> Void)?
    var volumeReceived: ((VolumeRequest, @escaping (VolumeReply) -> Void) -> Void)?
    var framesReceived: (([MotionFrame]) -> Void)?
    var activated: (() -> Void)?
    private(set) var streamUntil = 0.0
    private var telemetryInFlight = false
    private var session: WCSession?

    override init() {
        super.init()
        guard WCSession.isSupported() else { status = "Watch pairing unavailable"; return }
        session = .default
        session?.delegate = self
        session?.activate()
    }
    func sync(_ configuration: WizardryConfiguration) {
        guard configuration.isValid, let data = try? JSONEncoder().encode(configuration),
              let session, session.activationState == .activated else { return }
        do { try session.updateApplicationContext(["configuration":data]); status = "Settings queued · watch applies them when connected" }
        catch { status = "Settings sync failed: \(error.localizedDescription)" }
    }
    func requestStream() {
        guard let session, session.isReachable else { return }
        session.sendMessage(["streamUntil":Date().timeIntervalSince1970+25], replyHandler: nil, errorHandler: { _ in })
    }
    func stopStream() {
        guard let session, session.isReachable else { return }
        session.sendMessage(["streamUntil":0.0], replyHandler: nil, errorHandler: { _ in })
    }
    func sendFrames(_ frames: [MotionFrame]) {
        guard Date().timeIntervalSince1970 < streamUntil, !telemetryInFlight,
              let session, session.isReachable, let data = try? JSONEncoder().encode(frames) else { return }
        telemetryInFlight = true
        session.sendMessage(["frames":data], replyHandler: { [weak self] _ in
            Task { @MainActor in self?.telemetryInFlight = false }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in self?.telemetryInFlight = false }
        })
    }
    func send(_ event: GestureRequest, completion: @escaping (ActionResult) -> Void) {
        guard let session, session.activationState == .activated, session.isReachable,
              let data = try? JSONEncoder().encode(event) else {
            completion(.failure("iPhone unreachable. Open Wizardry on your phone.")); return
        }
        // WatchConnectivity sendMessage is immediate; action events never use background transfer queues.
        session.sendMessage(["gesture":data], replyHandler: { reply in
            let result = (reply["result"] as? Data).flatMap { try? JSONDecoder().decode(ActionResult.self,from:$0) }
            Task { @MainActor in completion(result ?? .failure("Invalid phone reply")) }
        }, errorHandler: { error in
            Task { @MainActor in completion(.failure("Phone: \(error.localizedDescription)")) }
        })
    }
    func sendVolume(_ request: VolumeRequest, completion: @escaping (VolumeReply) -> Void) {
        guard let session, session.activationState == .activated, session.isReachable,
              let data = try? JSONEncoder().encode(request) else {
            completion(.failure("iPhone unreachable",request:request)); return
        }
        session.sendMessage(["volume":data], replyHandler: { reply in
            let result = (reply["volumeReply"] as? Data).flatMap {try? JSONDecoder().decode(VolumeReply.self,from:$0)}
            Task { @MainActor in completion(result ?? .failure("Invalid volume reply",request:request)) }
        }, errorHandler: { error in
            Task { @MainActor in completion(.failure(error.localizedDescription,request:request)) }
        })
    }
    private func updateStatus() {
        reachable = session?.isReachable == true
        #if os(iOS)
        if session?.isPaired != true { status = "Pair your Apple Watch in Apple's Watch app" }
        else if session?.isWatchAppInstalled != true { status = "Install Wizardry on your Apple Watch" }
        else { status = reachable ? "Watch connected" : "Watch idle · open Wizardry to connect" }
        #else
        status = reachable ? "iPhone connected" : "iPhone unreachable"
        #endif
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        Task { @MainActor in
            self.updateStatus(); self.receiveContext(context); self.activated?()
            if let error { self.status = error.localizedDescription }
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.updateStatus() }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String:Any]) {
        Task { @MainActor in self.receiveContext(applicationContext) }
    }
    private func receiveContext(_ context: [String:Any]) {
        #if os(watchOS)
        if let data = context["configuration"] as? Data,
           let configuration = try? JSONDecoder().decode(WizardryConfiguration.self,from:data), configuration.isValid {
            configurationReceived?(configuration)
        }
        #endif
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String:Any]) {
        Task { @MainActor in self.receive(message, reply: nil) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String:Any], replyHandler: @escaping ([String:Any])->Void) {
        Task { @MainActor in self.receive(message,reply:replyHandler) }
    }
    private func receive(_ message: [String:Any], reply: (([String:Any])->Void)?) {
        #if os(watchOS)
        if let until = message["streamUntil"] as? Double, until.isFinite {
            streamUntil = min(until, Date().timeIntervalSince1970+30)
        }
        reply?(["ok":true])
        #else
        if let data = message["volume"] as? Data, let event = try? JSONDecoder().decode(VolumeRequest.self,from:data) {
            let respond: (VolumeReply)->Void = { result in
                if let encoded = try? JSONEncoder().encode(result) { reply?(["volumeReply":encoded]) }
            }
            guard let handler = volumeReceived else { respond(.failure("Phone is starting",request:event)); return }
            handler(event,respond); return
        }
        if let data = message["frames"] as? Data,
           let frames = try? JSONDecoder().decode([MotionFrame].self,from:data), frames.count <= 10 {
            framesReceived?(frames); reply?(["ok":true]); return
        }
        if let data = message["gesture"] as? Data, let event = try? JSONDecoder().decode(GestureRequest.self,from:data) {
            let respond: (ActionResult)->Void = { result in
                if let encoded = try? JSONEncoder().encode(result) { reply?(["result":encoded]) }
            }
            guard let handler = gestureReceived else { respond(.failure("Phone is starting; try again")); return }
            handler(event,respond); return
        }
        reply?(["ok":false])
        #endif
    }
    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}
