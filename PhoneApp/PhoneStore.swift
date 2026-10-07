import AVFoundation
import Combine
import Foundation
import MediaPlayer
import UIKit

@MainActor
final class PhoneStore: ObservableObject {
    @Published var configuration: WizardryConfiguration
    @Published var endpoint: String
    @Published var pairingToken = ""
    @Published var pairingStatus = "Enter your computer receiver's address and token"
    @Published private(set) var pairingBusy = false
    @Published private(set) var frames: [MotionFrame] = []
    @Published private(set) var lastTelemetry = Date.distantPast
    @Published private(set) var history: [ActionLog] = []
    @Published private(set) var busy = false
    @Published private(set) var lastVolumeReply: VolumeReply?
    @Published private(set) var watchDiagnostics: InteractionDiagnosticsSnapshot?
    let link = WatchLink()
    let home = HomeController()
    let spotify = SpotifyController()
    let phoneVolume = PhoneVolumeController()
    private var gate = CommandGate()
    private var volumeCoordinator = VolumeCommandCoordinator()
    private var volumeReplies: [UUID: (VolumeReply) -> Void] = [:]
    private var volumeBusy: Bool { volumeCoordinator.isBusy }
    private var player: AVAudioPlayer?
    private var chimeGeneration = 0
    private let network = ComputerClient()
    struct ActionLog: Identifiable {
        let id = UUID()
        let time = Date()
        var title: String
        var result: ActionResult
    }
    init() {
        let saved = UserDefaults.standard.data(forKey:"wizardryConfiguration").flatMap { try? JSONDecoder().decode(WizardryConfiguration.self,from:$0) }
        configuration = saved?.isValid == true ? saved! : WizardryConfiguration()
        endpoint = UserDefaults.standard.string(forKey:"serverURL") ?? ""
        pairingToken = PairingKeychain.load()
        link.activated = { [weak self] in guard let self else { return }; self.link.sync(self.configuration) }
        link.diagnosticsReceived = { [weak self] in self?.watchDiagnostics = $0 }
        link.framesReceived = { [weak self] frames in
            guard let self else { return }
            let clean = frames.filter { frame in
                [frame.time,frame.roll,frame.pitch,frame.yaw,frame.ax,frame.ay,frame.az,frame.rx,frame.ry,frame.rz,frame.gx,frame.gy,frame.gz,frame.hz].allSatisfy(\.isFinite) && abs(Date().timeIntervalSince1970-frame.time) < 5 && (frame.control?.isValid ?? true)
            }
            guard !clean.isEmpty else { return }
            self.frames.append(contentsOf:clean)
            if self.frames.count > 240 { self.frames.removeFirst(self.frames.count-240) }
            self.lastTelemetry = Date()
        }
        link.gestureReceived = { [weak self] event,reply in
            guard let self else { reply(.failure("Phone unavailable")); return }
            guard let binding = self.gate.accept(event,configuration:self.configuration,now:Date().timeIntervalSince1970) else {
                reply(.failure("Expired, duplicate, disabled, or out-of-date gesture. Sync settings and try again.")); return
            }
            guard !self.busy, !self.volumeBusy else { reply(.failure("Previous action still running")); return }
            Task {
                let task = UIApplication.shared.beginBackgroundTask(withName:"Wizardry action",expirationHandler:nil)
                let result = await self.perform(binding,deadline:event.createdAt+5)
                reply(result)
                if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            }
        }
        if UserDefaults.standard.bool(forKey:"homeEnabled") { home.connect() }
        link.volumeReceived = { [weak self] request,reply in
            guard let self else { reply(.failure("Phone unavailable",request:request)); return }
            guard !self.busy else { reply(.failure("Previous action still running",request:request)); return }
            let ticket = UUID()
            self.volumeReplies[ticket] = reply
            let effects = self.volumeCoordinator.receive(request,ticket:ticket,configuration:self.configuration,now:Date().timeIntervalSince1970)
            self.processVolume(effects)
        }
    }
    private func processVolume(_ effects: [VolumeCommandCoordinator.Effect]) {
        for effect in effects {
            switch effect {
            case let .reply(ticket,request,result):
                guard let reply = volumeReplies.removeValue(forKey:ticket) else { continue }
                // Superseded targets were never written and are not an actual
                // volume acknowledgement for the phone's UI either.
                if result.disposition != .superseded { lastVolumeReply = result }
                if request.operation == .end || result.outcome == .failed {
                    history.insert(.init(title:"Live volume",result:.init(outcome:result.outcome,message:result.message)),at:0)
                    if history.count > 30 { history.removeLast() }
                }
                reply(result)
            case let .execute(ticket,request,profileID):
                let phone = profileID == "phone"
                let endpoint = UserDefaults.standard.string(forKey:"serverURL") ?? ""
                let token = PairingKeychain.load()
                Task {
                    let task: UIBackgroundTaskIdentifier = phone ? .invalid : UIApplication.shared.beginBackgroundTask(withName:"Wizardry live volume",expirationHandler:nil)
                    defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
                    let result: VolumeReply
                    guard self.volumeCoordinator.isCurrentExecution(ticket),
                          request.revision == self.configuration.revision,
                          profileID == self.configuration.selectedProfileID,
                          Date().timeIntervalSince1970 < request.createdAt+1 else {
                        let failure = VolumeReply.failure("Volume session changed or request expired; not retried",request:request)
                        let effects = self.volumeCoordinator.complete(ticket:ticket,result:failure,now:Date().timeIntervalSince1970)
                        self.processVolume(effects)
                        return
                    }
                    if phone { result = await self.phoneVolume.volume(request) }
                    else { result = await self.network.volume(request,endpoint:endpoint,token:token) }
                    let effects = self.volumeCoordinator.complete(ticket:ticket,result:result,now:Date().timeIntervalSince1970)
                    self.processVolume(effects)
                }
            }
        }
        if !volumeCoordinator.hasSession { phoneVolume.stop() }
    }
    private func invalidateVolume(_ message: String) {
        phoneVolume.stop()
        let effects = volumeCoordinator.invalidate(now:Date().timeIntervalSince1970,message:message)
        processVolume(effects)
    }
    func saveConfiguration() {
        guard configuration.isValid else { return }
        invalidateVolume("Settings changed. Activate again.")
        configuration.revision = UUID().uuidString
        if let data = try? JSONEncoder().encode(configuration) { UserDefaults.standard.set(data,forKey:"wizardryConfiguration") }
        link.sync(configuration)
    }
    func connectHome() { UserDefaults.standard.set(true,forKey:"homeEnabled"); home.connect() }
    func pairComputer() async {
        guard !pairingBusy else { return }
        let token = pairingToken.trimmingCharacters(in:.whitespacesAndNewlines)
        let address = endpoint.trimmingCharacters(in:.whitespacesAndNewlines)
        guard token.count >= 16 else { pairingStatus = "Use a pairing token of at least 16 characters"; return }
        pairingBusy = true
        defer { pairingBusy = false }
        pairingStatus = "Checking receiver…"
        let result = await network.send("ping",endpoint:address,token:token)
        guard result.outcome != .failed else { pairingStatus = result.message; return }
        do {
            try PairingKeychain.save(token)
            invalidateVolume("Receiver pairing changed. Activate again.")
            UserDefaults.standard.set(address,forKey:"serverURL")
            pairingToken = token
            endpoint = address
            pairingStatus = "Paired · receiver responded. Test an action below."
        } catch { pairingStatus = error.localizedDescription }
    }
    func test(_ binding: GestureBinding) { Task { _ = await perform(binding,deadline:Date().timeIntervalSince1970+5) } }
    func clearFrames() { frames = []; lastTelemetry = .distantPast }
    func suspendPhoneVolume() {
        if configuration.selectedProfileID == "phone" { invalidateVolume("Keep Wizardry open on iPhone. Activate again.") }
    }
    private func perform(_ binding: GestureBinding, deadline: Double) async -> ActionResult {
        guard !busy, !volumeBusy, !phoneVolume.isActive, Date().timeIntervalSince1970 <= deadline else { return .failure("Action expired or phone is busy") }
        busy = true; defer { busy = false }
        let result: ActionResult
        if let command = binding.action.computerCommand {
            result = await network.send(command,endpoint:UserDefaults.standard.string(forKey:"serverURL") ?? "",token:PairingKeychain.load())
        } else if binding.action.isHomePower || binding.action == .homeScene {
            result = await home.perform(binding,deadline:deadline)
        } else if [.spotifyPlayPause,.spotifyNext,.spotifyPrevious,.spotifyVolumeUp,.spotifyVolumeDown].contains(binding.action) {
            result = await spotify.perform(binding.action,deadline:deadline)
        } else {
            switch binding.action {
            case .haptic: result = .failure("Try this gesture on the watch to feel its haptic")
            case .phonePing: result = chime()
            case .phonePlayPause,.phoneNext,.phonePrevious:
                guard MPMediaLibrary.authorizationStatus() == .authorized else {
                    let denied = ActionResult.failure("Allow Apple Music in Setup first"); record(binding,denied); return denied
                }
                let music = MPMusicPlayerController.systemMusicPlayer
                if binding.action == .phoneNext { music.skipToNextItem() }
                else if binding.action == .phonePrevious { music.skipToPreviousItem() }
                else if music.playbackState == .playing { music.pause() } else { music.play() }
                result = .init(outcome:.handedOff,message:"Sent to Apple Music · start a queue in Music first")
            case .shortcut:
                let name = binding.shortcutName.trimmingCharacters(in:.whitespacesAndNewlines)
                guard !name.isEmpty, UIApplication.shared.applicationState == .active else {
                    let denied = ActionResult.failure("Keep Wizardry open on iPhone to launch a named Shortcut"); record(binding,denied); return denied
                }
                var url = URLComponents(); url.scheme = "shortcuts"; url.host = "run-shortcut"
                url.queryItems = [URLQueryItem(name:"name",value:name)]
                let opened = await UIApplication.shared.open(url.url!)
                result = opened ? .init(outcome:.handedOff,message:"Opened Shortcut: \(name) · completion is not reported") : .failure("Could not open Shortcuts")
            default: result = .failure("Action not configured")
            }
        }
        record(binding,result); return result
    }
    private func record(_ binding: GestureBinding, _ result: ActionResult) {
        history.insert(.init(title:binding.gesture.title,result:result),at:0)
        if history.count > 30 { history.removeLast() }
    }
    private func chime() -> ActionResult {
        guard let url = Bundle.main.url(forResource:"locator",withExtension:"wav") else { return .failure("Locator sound unavailable") }
        do {
            chimeGeneration += 1
            let generation = chimeGeneration
            try AVAudioSession.sharedInstance().setCategory(.playback,mode:.default,options:[.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf:url)
            guard player?.play() == true else { return .failure("Could not play locator sound") }
            Task { try? await Task.sleep(for:.seconds(3)); if generation == chimeGeneration {
                player?.stop(); try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)
            } }
            return .init(outcome:.executed,message:"Locator chime played on iPhone")
        } catch { return .failure(error.localizedDescription) }
    }
}

final class ComputerClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let clockLock = NSLock()
    private var clockState: (endpoint: String, token: String, sample: ReceiverClockAlignment)?
    private func clock(endpoint: String, token: String) -> ReceiverClockAlignment? {
        clockLock.withLock {
            guard let state = clockState, state.endpoint == endpoint, state.token == token,
                  Date().timeIntervalSince1970-state.sample.receivedAt <= 30 else { return nil }
            return state.sample
        }
    }
    private func rememberClock(_ serverTime: Double, endpoint: String, token: String) {
        guard serverTime.isFinite else { return }
        let sample = ReceiverClockAlignment(serverTime:serverTime,receivedAt:Date().timeIntervalSince1970)
        clockLock.withLock { clockState = (endpoint,token,sample) }
    }
    private func sampleClock(base: URL, token: String, deadline: Double) async -> ActionResult? {
        let remaining = deadline-Date().timeIntervalSince1970
        guard remaining > 0 else { return .failure("Live request expired before checking receiver time. Activate again.") }
        var ping = URLRequest(url:base.appendingPathComponent("command"),timeoutInterval:min(1,remaining))
        ping.httpMethod = "POST"
        ping.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        ping.setValue("application/json",forHTTPHeaderField:"Content-Type")
        ping.httpBody = try? JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"command":"ping","timestamp":Date().timeIntervalSince1970])
        do {
            let (data,response) = try await session.data(for:ping)
            guard let http = response as? HTTPURLResponse else { return .failure("Invalid receiver clock response") }
            guard http.statusCode == 200 else { return .failure(ReceiverFailure.message(status:http.statusCode,data:data,token:token)) }
            guard let body = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  body["liveVolume"] as? Bool == true,
                  let version = body["liveVolumeProtocol"] as? Int, version >= 2,
                  let time = body["serverTime"] as? Double, time.isFinite else {
                return .failure("Update and restart receiver/server.py before using live volume (transport version 2 required).")
            }
            rememberClock(time,endpoint:base.absoluteString,token:token)
            return nil
        } catch { return .failure("Receiver time check failed: \(error.localizedDescription)") }
    }
    func volume(_ event: VolumeRequest, endpoint: String, token: String) async -> VolumeReply {
        guard let base = URL(string:endpoint.trimmingCharacters(in:.whitespacesAndNewlines)),
              ["http","https"].contains(base.scheme ?? ""),base.host != nil,base.user == nil,base.password == nil,
              base.query == nil,base.fragment == nil,token.count >= 16,
              Date().timeIntervalSince1970-event.createdAt <= 1 else { return .failure("Pair receiver, or request expired",request:event) }
        if event.operation == .begin || clock(endpoint:base.absoluteString,token:token) == nil {
            if let failure = await sampleClock(base:base,token:token,deadline:event.createdAt+1) {
                return .failure(failure.message,request:event)
            }
        }
        let now = Date().timeIntervalSince1970
        guard let sample = clock(endpoint:base.absoluteString,token:token),
              let timestamp = sample.translate(createdAt:event.createdAt,now:now), event.createdAt+1 > now else {
            return .failure("Live request expired during clock alignment. Activate again; not retried.",request:event)
        }
        var wire = event; wire.createdAt = timestamp
        var request = URLRequest(url:base.appendingPathComponent("volume"),timeoutInterval:min(1,event.createdAt+1-now))
        request.httpMethod = "POST"
        request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody = try? JSONEncoder().encode(wire)
        do {
            let (data,response) = try await session.data(for:request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("Invalid receiver HTTP response",request:event)
            }
            guard http.statusCode == 200 else {
                return .failure(ReceiverFailure.message(status:http.statusCode,data:data,token:token),request:event)
            }
            let result = try JSONDecoder().decode(VolumeReply.self,from:data)
            guard result.sessionID == event.sessionID, result.sequence == event.sequence,
                  result.outcome == .executed || result.outcome == .dryRun,
                  result.disposition != .superseded,
                  let volume = result.volume, volume.isFinite, (0...1).contains(volume) else {
                return .failure("Invalid volume acknowledgement",request:event)
            }
            guard event.operation != .begin || (result.transportVersion ?? 0) >= 2 else {
                return .failure("Update and restart receiver/server.py before using live volume (transport version 2 required).",request:event)
            }
            if let time = result.serverTime { rememberClock(time,endpoint:base.absoluteString,token:token) }
            return result
        } catch { return .failure("Volume connection failed: \(error.localizedDescription)",request:event) }
    }
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4; config.timeoutIntervalForResource = 5; config.waitsForConnectivity = false
        return URLSession(configuration:config,delegate:self,delegateQueue:nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?)->Void) { completionHandler(nil) }
    func send(_ command: String, endpoint: String, token: String) async -> ActionResult {
        guard let base = URL(string:endpoint.trimmingCharacters(in:.whitespacesAndNewlines)),
              ["http","https"].contains(base.scheme ?? ""),base.host != nil,base.user == nil,base.password == nil,
              base.query == nil,base.fragment == nil,token.count >= 16 else { return .failure("Pair the computer in Setup first") }
        var request = URLRequest(url:base.appendingPathComponent("command")); request.httpMethod = "POST"
        request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"command":command,"timestamp":Date().timeIntervalSince1970])
        do {
            let (data,response) = try await session.data(for:request)
            guard let http = response as? HTTPURLResponse else { return .failure("Invalid receiver response") }
            guard http.statusCode == 200 else { return .failure(ReceiverFailure.message(status:http.statusCode,data:data,token:token)) }
            guard let body = try JSONSerialization.jsonObject(with:data) as? [String:Any], let executed = body["executed"] as? Bool else { return .failure("Invalid receiver acknowledgement") }
            return .init(outcome:executed ? .executed : .dryRun,message:executed ? "Computer: \(command)" : "Receiver acknowledged · dry run / ping")
        } catch { return .failure("Computer unavailable: \(error.localizedDescription)") }
    }
}
