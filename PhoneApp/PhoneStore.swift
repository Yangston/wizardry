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
    @Published private(set) var frames: [MotionFrame] = []
    @Published private(set) var lastTelemetry = Date.distantPast
    @Published private(set) var history: [ActionLog] = []
    @Published private(set) var busy = false
    let link = WatchLink()
    let home = HomeController()
    let spotify = SpotifyController()
    private var gate = CommandGate()
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
        link.framesReceived = { [weak self] frames in
            guard let self else { return }
            let clean = frames.filter { frame in
                [frame.time,frame.roll,frame.pitch,frame.yaw,frame.ax,frame.ay,frame.az,frame.rx,frame.ry,frame.rz,frame.gx,frame.gy,frame.gz,frame.hz].allSatisfy(\.isFinite) && abs(Date().timeIntervalSince1970-frame.time) < 5
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
            guard !self.busy else { reply(.failure("Previous action still running")); return }
            Task {
                let task = UIApplication.shared.beginBackgroundTask(withName:"Wizardry action",expirationHandler:nil)
                let result = await self.perform(binding,deadline:event.createdAt+5)
                reply(result)
                if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            }
        }
        if UserDefaults.standard.bool(forKey:"homeEnabled") { home.connect() }
    }
    func saveConfiguration() {
        guard configuration.isValid else { return }
        configuration.revision = UUID().uuidString
        if let data = try? JSONEncoder().encode(configuration) { UserDefaults.standard.set(data,forKey:"wizardryConfiguration") }
        link.sync(configuration)
    }
    func connectHome() { UserDefaults.standard.set(true,forKey:"homeEnabled"); home.connect() }
    func pairComputer() async {
        guard pairingToken.count >= 16 else { pairingStatus = "Use a pairing token of at least 16 characters"; return }
        do {
            try PairingKeychain.save(pairingToken)
            UserDefaults.standard.set(endpoint,forKey:"serverURL")
            let result = await network.send("ping",endpoint:endpoint,token:pairingToken)
            pairingStatus = result.outcome == .failed ? result.message : "Paired · receiver responded. Test an action below."
        } catch { pairingStatus = error.localizedDescription }
    }
    func test(_ binding: GestureBinding) { Task { _ = await perform(binding,deadline:Date().timeIntervalSince1970+5) } }
    func clearFrames() { frames = []; lastTelemetry = .distantPast }
    private func perform(_ binding: GestureBinding, deadline: Double) async -> ActionResult {
        guard !busy, Date().timeIntervalSince1970 <= deadline else { return .failure("Action expired or phone is busy") }
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
            case .haptic: result = .init(outcome:.executed,message:"Haptic confirms gesture on watch")
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
            guard http.statusCode == 200 else { return .failure("Receiver error \(http.statusCode) · check token, version, and clock") }
            guard let body = try JSONSerialization.jsonObject(with:data) as? [String:Any], let executed = body["executed"] as? Bool else { return .failure("Invalid receiver acknowledgement") }
            return .init(outcome:executed ? .executed : .dryRun,message:executed ? "Computer: \(command)" : "Receiver acknowledged · dry run / ping")
        } catch { return .failure("Computer unavailable: \(error.localizedDescription)") }
    }
}
