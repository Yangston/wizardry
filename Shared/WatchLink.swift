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
    var diagnosticsReceived: ((InteractionDiagnosticsSnapshot) -> Void)?
    var configurationAcknowledged: ((String) -> Void)?
    var controlRequestReceived: ((ControlConnectionRequest, @escaping (ControlConnectionReply) -> Void) -> Void)?
    var sensorBatchReceived: ((SensorBatch) -> Void)?
    var studioRequestReceived: ((Bool, Double) -> Bool)?
    var activated: (() -> Void)?
    private(set) var streamUntil = 0.0
    private var telemetryInFlight = false
    private var sensorBatchInFlight: UUID?
    private var lastStudioRequestTime = -Double.infinity
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
        if session.isReachable {
            session.sendMessage(["configuration":data],replyHandler:{ [weak self] reply in
                guard let revision = reply["configurationRevision"] as? String, revision == configuration.revision else { return }
                Task { @MainActor in self?.configurationAcknowledged?(revision) }
            },errorHandler:{ _ in })
        }
    }
    func requestControl(_ request: ControlConnectionRequest, completion: @escaping (Result<ControlConnectionReply,Error>) -> Void) {
        guard request.isValid, let session, session.activationState == .activated, session.isReachable,
              let data = try? JSONEncoder().encode(request) else {
            completion(.failure(NSError(domain:"Wizardry",code:1,userInfo:[NSLocalizedDescriptionKey:"iPhone link offline. Open Wizardry on your iPhone."]))); return
        }
        session.sendMessage(["controlConnection":data],replyHandler:{ reply in
            let value = (reply["controlConnectionReply"] as? Data).flatMap {try? JSONDecoder().decode(ControlConnectionReply.self,from:$0)}
            Task { @MainActor in
                if let value, value.id == request.id, value.isValid { completion(.success(value)) }
                else { completion(.failure(NSError(domain:"Wizardry",code:2,userInfo:[NSLocalizedDescriptionKey:"Update both Wizardry apps to confirm the control target."]))) }
            }
        },errorHandler:{ error in Task { @MainActor in completion(.failure(error)) } })
    }
    func requestStudio(until: Double, recording: Bool, completion: @escaping (Bool) -> Void) {
        guard until.isFinite, let session, session.isReachable else { completion(false); return }
        session.sendMessage(["studioUntil":until,"studioRecording":recording,"studioIssuedAt":Date().timeIntervalSince1970],replyHandler:{ reply in
            let accepted = reply["studioRecording"] as? Bool == recording && reply["studioAccepted"] as? Bool == true
            Task { @MainActor in completion(accepted) }
        },errorHandler:{ _ in Task { @MainActor in completion(false) } })
    }
    /// One bounded sample batch on the link. Rejected samples are counted by
    /// the capture owner, rather than hidden or replayed after reconnection.
    func sendSensorBatch(_ batch: SensorBatch) -> Bool {
        guard sensorBatchInFlight == nil, batch.isValid, let session, session.isReachable,
              let data = try? JSONEncoder().encode(batch), data.count <= 200_000 else { return false }
        let ticket = UUID(); sensorBatchInFlight = ticket
        session.sendMessage(["sensorBatch":data],replyHandler:{ [weak self] _ in
            Task { @MainActor in if self?.sensorBatchInFlight == ticket { self?.sensorBatchInFlight = nil } }
        },errorHandler:{ [weak self] _ in
            Task { @MainActor in if self?.sensorBatchInFlight == ticket { self?.sensorBatchInFlight = nil } }
        })
        return true
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
    /// Best-effort state evidence, including the final transition after capture
    /// stops. Never enters a background transfer queue or retries.
    func sendDiagnostics(_ snapshot: InteractionDiagnosticsSnapshot) {
        guard Date().timeIntervalSince1970 < streamUntil, snapshot.isValid, let session, session.isReachable,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        session.sendMessage(["interactionDiagnostics":data],replyHandler:nil,errorHandler:{ _ in })
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
        if let data = message["configuration"] as? Data,
           let config = try? JSONDecoder().decode(WizardryConfiguration.self,from:data), config.isValid {
            configurationReceived?(config); reply?(["configurationRevision":config.revision]); return
        }
        if let until = message["studioUntil"] as? Double, until.isFinite {
            let now = Date().timeIntervalSince1970
            guard let issued = message["studioIssuedAt"] as? Double, issued.isFinite,
                  issued >= lastStudioRequestTime, issued <= now+0.1, now-issued <= 5 else {
                reply?(["studioAccepted":false,"studioRecording":false]); return
            }
            lastStudioRequestTime = issued
            let recording = message["studioRecording"] as? Bool == true
            let accepted = studioRequestReceived?(recording,min(until,Date().timeIntervalSince1970+5)) == true
            reply?(["studioAccepted":accepted,"studioRecording":accepted && recording]); return
        }
        if let until = message["streamUntil"] as? Double, until.isFinite {
            streamUntil = min(until, Date().timeIntervalSince1970+30)
        }
        reply?(["ok":true])
        #else
        if let data = message["controlConnection"] as? Data, data.count <= 8192,
           let request = try? JSONDecoder().decode(ControlConnectionRequest.self,from:data), request.isValid,
           let handler = controlRequestReceived {
            handler(request) { response in
                if let data = try? JSONEncoder().encode(response) { reply?(["controlConnectionReply":data]) }
            }
            return
        }
        if let data = message["sensorBatch"] as? Data, data.count <= 200_000,
           let batch = try? JSONDecoder().decode(SensorBatch.self,from:data), batch.isValid {
            sensorBatchReceived?(batch); reply?(["ok":true]); return
        }
        if let data = message["interactionDiagnostics"] as? Data, data.count <= 32_768,
           let snapshot = try? JSONDecoder().decode(InteractionDiagnosticsSnapshot.self,from:data), snapshot.isValid {
            diagnosticsReceived?(snapshot); reply?(["ok":true]); return
        }
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
