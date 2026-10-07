import Combine
import Foundation
import UIKit

/// Foreground-only, explicitly enabled sensor relay. This connection observes
/// motion and synchronizes mappings; it never selects or executes an action.
@MainActor
final class DesktopStudioRelay: NSObject, ObservableObject, URLSessionTaskDelegate {
    @Published private(set) var enabled = false
    @Published private(set) var status = "Computer studio is off"
    @Published private(set) var recording = false
    @Published private(set) var forwardedSamples = 0
    @Published private(set) var droppedSamples = 0
    var configuration: (() -> WizardryConfiguration)?
    var applyMapping: ((DesktopMappingEdit) -> String?)?
    var recordingChanged: ((Bool) -> Void)?
    private let link: WatchLink
    private lazy var session: URLSession = {
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 2; settings.timeoutIntervalForResource = 3
        settings.waitsForConnectivity = false
        return URLSession(configuration:settings,delegate:self,delegateQueue:nil)
    }()
    private var foreground = false
    private var task: Task<Void,Never>?
    private var generation = 0
    private var forwarding = false
    private var telemetryRequested = false
    private var watchRecording = false
    private var appliedMappingEditID: UUID?
    private var mappingError: String?
    private var idleTimerPrevious: Bool?
    private var requestID = UUID()
    private var receiverClock: ReceiverClockAlignment?

    init(link: WatchLink) {
        self.link = link
        super.init()
        link.sensorBatchReceived = { [weak self] batch in self?.forward(batch) }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func setEnabled(_ value: Bool) {
        enabled = value
        if value { startIfNeeded() } else { stop("Computer studio is off") }
    }
    func setForeground(_ value: Bool) {
        foreground = value
        if value { startIfNeeded() }
        else { stop(enabled ? "Studio paused · keep Wizardry open on iPhone" : "Computer studio is off") }
    }
    private func startIfNeeded() {
        guard enabled, foreground, task == nil else { return }
        generation += 1; let current = generation
        status = "Connecting to computer studio…"
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.enabled, self.foreground, self.generation == current else { return }
                await self.poll(generation:current)
                do { try await Task.sleep(for:.milliseconds(500)) } catch { return }
            }
        }
    }
    private func setRecording(_ value: Bool) {
        guard recording != value else { return }
        recording = value; recordingChanged?(value)
        if value {
            idleTimerPrevious = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        } else if let previous = idleTimerPrevious {
            UIApplication.shared.isIdleTimerDisabled = previous; idleTimerPrevious = nil
        }
    }
    private func stop(_ message: String) {
        generation += 1; requestID = UUID(); task?.cancel(); task = nil
        telemetryRequested = false; watchRecording = false; setRecording(false)
        receiverClock = nil
        link.requestStudio(until:0,recording:false) { _ in }
        status = message
    }
    private func request<T: Encodable>(_ path: String, body: T) throws -> URLRequest {
        let endpoint = UserDefaults.standard.string(forKey:"serverURL") ?? ""
        let token = PairingKeychain.load()
        guard let base = URL(string:endpoint), ["http","https"].contains(base.scheme ?? ""),
              base.host != nil, base.user == nil, base.password == nil, base.query == nil, base.fragment == nil, token.count >= 16 else {
            throw NSError(domain:"Wizardry",code:1,userInfo:[NSLocalizedDescriptionKey:"Pair your computer in Setup first."])
        }
        var request = URLRequest(url:base.appendingPathComponent(path))
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(body)
        request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        return request
    }
    private func poll(generation current: Int) async {
        guard let configuration = configuration?() else { return }
        do {
            var body = DesktopStudioPoll(configuration:configuration,appliedMappingEditID:appliedMappingEditID,
                                         mappingError:mappingError,watchRecording:watchRecording)
            if let aligned = receiverClock?.translate(createdAt:body.createdAt,now:body.createdAt,maximumAge:5) { body.createdAt = aligned }
            let request = try request("studio",body:body)
            let (data,response) = try await session.data(for:request)
            guard current == generation, enabled, foreground else { return }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                if (response as? HTTPURLResponse)?.statusCode == 408,
                   let error = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                   let serverTime = error["serverTime"] as? Double, serverTime.isFinite {
                    receiverClock = .init(serverTime:serverTime,receivedAt:Date().timeIntervalSince1970)
                    status = "Computer clock aligned · waiting for a fresh studio poll"
                    return
                }
                status = "Computer studio unavailable · update/restart the receiver and check pairing"
                telemetryRequested = false; setRecording(false)
                link.requestStudio(until:0,recording:false) { _ in }; return
            }
            let reply = try JSONDecoder().decode(DesktopStudioReply.self,from:data)
            guard reply.ok, reply.studioProtocol == 1 else { throw URLError(.badServerResponse) }
            if let serverTime = reply.serverTime, serverTime.isFinite {
                receiverClock = .init(serverTime:serverTime,receivedAt:Date().timeIntervalSince1970)
            }
            if let edit = reply.pendingMappingEdit, edit.id != appliedMappingEditID {
                mappingError = applyMapping?(edit)
                if applyMapping == nil { mappingError = "iPhone mapping handler unavailable" }
                appliedMappingEditID = edit.id
            }
            telemetryRequested = reply.telemetryRequested
            setRecording(reply.recording && reply.telemetryRequested)
            let ticket = UUID(); requestID = ticket
            link.requestStudio(until:reply.telemetryRequested ? Date().timeIntervalSince1970+3 : 0,recording:recording) { [weak self] accepted in
                guard let self, self.generation == current, self.requestID == ticket else { return }
                self.watchRecording = accepted && self.recording
                self.status = !reply.telemetryRequested ? "Studio connected · start live sensors on computer" :
                    accepted ? (self.recording ? "Recording · Watch actions off" : "Streaming motion to computer") : "Open Wizardry on Watch to stream sensors"
            }
        } catch {
            guard current == generation else { return }
            status = "Computer studio disconnected · check receiver and pairing"
            telemetryRequested = false; setRecording(false)
            link.requestStudio(until:0,recording:false) { _ in }
        }
    }
    private func forward(_ batch: SensorBatch) {
        guard enabled, foreground, telemetryRequested, batch.isValid else { return }
        let now = Date().timeIntervalSince1970
        guard !forwarding, (-0.1...2).contains(now-batch.createdAt),
              batch.samples.allSatisfy({(-0.1...3).contains(now-$0.wallTime)}) else {
            droppedSamples += batch.samples.count; return
        }
        forwarding = true
        let current = generation
        var outgoing = batch; outgoing.droppedSamples += droppedSamples
        let countedDrops = droppedSamples
        Task { [weak self] in
            guard let self else { return }
            defer { self.forwarding = false }
            do {
                guard current == self.generation, let clock = self.receiverClock,
                      let timestamp = clock.translate(createdAt:batch.createdAt,now:Date().timeIntervalSince1970,maximumAge:2) else {
                    throw URLError(.timedOut)
                }
                outgoing.createdAt = timestamp
                let request = try self.request("telemetry",body:outgoing)
                let (_,response) = try await self.session.data(for:request)
                guard current == self.generation else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                self.forwardedSamples += batch.samples.count
                self.droppedSamples = max(0,self.droppedSamples-countedDrops)
            } catch {
                guard current == self.generation else { return }
                self.droppedSamples += batch.samples.count
                self.status = "Sensor batch dropped · recording quality will show the gap"
            }
        }
    }
}
