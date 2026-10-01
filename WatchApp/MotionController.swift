import Combine
import CoreMotion
import Foundation
import WatchKit

@MainActor
final class MotionController: ObservableObject {
    enum Screen: Hashable { case nowPlaying, guide }
    static let shared = MotionController()
    @Published var navigationPath: [Screen] = []
    @Published private(set) var activatingFromShortcut = false
    @Published private(set) var configuration = WizardryConfiguration()
    @Published private(set) var running = false
    @Published private(set) var sessionActive = false
    @Published private(set) var status = "Start a control session"
    @Published private(set) var armed = false
    @Published private(set) var armRemaining = 0
    @Published private(set) var rollDegrees = 0.0
    @Published private(set) var sampleRate = 0.0
    @Published private(set) var count = 0
    @Published private(set) var lastGesture = "None yet"
    @Published private(set) var actionStatus = "Set up actions on your iPhone"
    @Published private(set) var actionFailed = false
    let link = WatchLink()
    private let manager = CMMotionManager()
    private var engine = GestureEngine()
    private var activation = ShortcutActivation()
    private var sceneActive = false
    private var activationTimeoutTask: Task<Void,Never>?
    private var generation = 0
    private var lastDisplay = 0.0
    private var firstSample: Double?
    private var samples = 0
    private var buffer: [MotionFrame] = []
    private var sessionEnd: Date?
    private var actionID: UUID?
    private var expiryTask: Task<Void,Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey:"watchConfiguration"),
           let saved = try? JSONDecoder().decode(WizardryConfiguration.self,from:data), saved.isValid { configuration = saved }
        link.configurationReceived = { [weak self] config in
            guard let self else { return }
            let changed = self.configuration != config
            self.configuration = config
            if let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data,forKey:"watchConfiguration") }
            if changed {
                if self.activation.isPending { self.stop("Settings changed · activate again") }
                else { self.configureEngine() }
                self.actionID = nil
            }
            self.actionStatus = "Synced: \(config.selectedProfile.name)"; self.actionFailed = false
        }
        configureEngine()
    }
    private func configureEngine() {
        engine.reset(); engine.requireWake = configuration.requireWake; engine.threshold = configuration.threshold; engine.armSeconds = configuration.armSeconds
        armed = false; armRemaining = 0
    }
    func start() {
        cancelShortcutActivation()
        startSession()
    }
    private func startSession() {
        sessionEnd = Date().addingTimeInterval(30*60); sessionActive = true
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(1)) } catch { return }
                guard let self, let end = self.sessionEnd else { return }
                if Date() >= end { self.stop("Session ended after 30 minutes"); return }
            }
        }
        resume()
    }
    func resume() {
        guard sceneActive, navigationPath.last != .nowPlaying, sessionActive, !running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if activation.expire(at:now) { stop("Activation timed out · activate again"); return }
        guard let end = sessionEnd, Date() < end else { stop("Session expired — start again"); return }
        guard manager.isDeviceMotionAvailable else { stop("Motion unavailable on this device"); return }
        configureEngine(); firstSample = nil; samples = 0; lastDisplay = 0; buffer = []; sampleRate = 0
        generation += 1; let capture = generation
        activation.beginCapture(at:now)
        running = true
        status = activation.isPending ? "Hold still · preparing gestures" : (configuration.requireWake ? "Double twist to wake" : "Ready for a gesture")
        manager.deviceMotionUpdateInterval = 1.0/50
        manager.startDeviceMotionUpdates(to:.main) { [weak self] motion,error in
            guard let motion else {
                Task { @MainActor [weak self] in
                    guard let self, self.generation == capture else { return }
                    self.stop(error?.localizedDescription ?? "Motion unavailable")
                }; return
            }
            let t = motion.timestamp, roll = motion.attitude.roll, pitch = motion.attitude.pitch, yaw = motion.attitude.yaw
            let a = motion.userAcceleration, r = motion.rotationRate, g = motion.gravity
            Task { @MainActor [weak self] in
                guard let self, self.running, self.generation == capture else { return }
                self.consume(time:t,roll:roll,pitch:pitch,yaw:yaw,ax:a.x,ay:a.y,az:a.z,rx:r.x,ry:r.y,rz:r.z,gx:g.x,gy:g.y,gz:g.z)
            }
        }
    }
    func pause(_ message: String = "Paused · raise wrist to resume") {
        cancelShortcutActivation()
        suspendCapture(message)
    }
    private func suspendCapture(_ message: String) {
        generation += 1; manager.stopDeviceMotionUpdates(); running = false; buffer = []; configureEngine()
        if sessionActive { status = message }
    }
    func setSceneActive(_ active: Bool) {
        sceneActive = active
        if active { resume() }
        else {
            // A Shortcut may arrive before the first active scene notification.
            // Preserve that waiting request, but never resume a started calibration.
            activation.leaveForeground()
            if !activation.isPending { cancelShortcutActivation() }
            suspendCapture(activation.isPending ? "Opening control · hold still" : "Paused · raise wrist to resume")
        }
    }
    func navigationChanged() {
        if navigationPath.last == .nowPlaying { pause("Paused for Now Playing") }
        else { resume() }
    }
    func activateFromShortcut() {
        // Invalidate queued sensor callbacks as well as any earlier launch request.
        pause()
        activation.request(at:ProcessInfo.processInfo.systemUptime)
        activatingFromShortcut = true
        navigationPath = []
        status = "Opening control · hold still"
        activationTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for:.seconds(ShortcutActivation.timeout)) } catch { return }
            guard let self, self.activation.expire(at:ProcessInfo.processInfo.systemUptime) else { return }
            self.stop("Activation timed out · activate again")
        }
        startSession()
    }
    private func cancelShortcutActivation() {
        activation.cancel()
        activatingFromShortcut = false
        activationTimeoutTask?.cancel()
        activationTimeoutTask = nil
    }
    func stop(_ message: String = "Session stopped") {
        pause(); sessionActive = false; sessionEnd = nil; expiryTask?.cancel(); expiryTask = nil; status = message
        actionID = nil
    }
    func arm() {
        cancelShortcutActivation()
        if !sessionActive { start() }
        guard running else { return }
        engine.arm(time:ProcessInfo.processInfo.systemUptime); armed = true; status = "Return to neutral, then act"
        WKInterfaceDevice.current().play(.success)
    }
    func testHaptic() { WKInterfaceDevice.current().play(.click) }
    private func consume(time: Double,roll: Double,pitch: Double,yaw: Double,ax: Double,ay: Double,az: Double,rx: Double,ry: Double,rz: Double,gx: Double,gy: Double,gz: Double) {
        guard let end = sessionEnd, Date() < end else { stop("Session expired — start again"); return }
        if firstSample == nil { firstSample = time }
        samples += 1
        let acceleration = sqrt(ax*ax+ay*ay+az*az)
        let now = ProcessInfo.processInfo.systemUptime
        if activation.isPending {
            // Never feed launch motion to the action recognizer, even with wake disabled.
            let event = activation.update(roll:roll,pitch:pitch,acceleration:acceleration,
                                          rotationRate:sqrt(rx*rx+ry*ry+rz*rz),sampleTime:time,
                                          now:now)
            switch event {
            case .ready:
                cancelShortcutActivation()
                engine.calibrateAndArm(roll:roll,pitch:pitch,sampleTime:time,readyTime:now)
                armed = true; armRemaining = Int(ceil(configuration.armSeconds))
                status = "Ready · make a gesture"
                WKInterfaceDevice.current().play(.success)
            case .timedOut: stop("Activation timed out · activate again"); return
            case .invalidMotion: stop("Motion unavailable · activate again"); return
            case nil: break
            }
        } else if let event = engine.update(roll:roll,pitch:pitch,acceleration:acceleration,time:time) {
            switch event {
            case .woke: WKInterfaceDevice.current().play(.success); status = "Return to neutral, then act"
            case .action(let gesture):
                guard let binding = configuration.selectedProfile.bindings.first(where:{$0.gesture == gesture && $0.enabled}) else { return }
                count += 1; lastGesture = gesture.title; WKInterfaceDevice.current().play(.click)
                if binding.action == .haptic { actionStatus = "Haptic only"; actionFailed = false }
                else { send(gesture) }
            }
        }
        if time-lastDisplay >= 0.1 {
            armed = engine.isArmed
            armRemaining = armed ? max(0,Int(ceil(engine.armedUntil-now))) : 0
            if activation.isPending { status = "Hold still · preparing gestures" }
            else if !armed { status = configuration.requireWake ? "Double twist to wake" : "Ready for a gesture" }
            else { status = "Armed · \(armRemaining)s" }
            rollDegrees = engine.relativeRoll*180 / .pi
            let elapsed = time-(firstSample ?? time); sampleRate = elapsed > 0 ? Double(samples-1)/elapsed : 0
            lastDisplay = time
            if Date().timeIntervalSince1970 < link.streamUntil {
                buffer.append(.init(time:Date().timeIntervalSince1970,roll:engine.relativeRoll,pitch:engine.relativePitch,yaw:yaw,
                    ax:ax,ay:ay,az:az,rx:rx,ry:ry,rz:rz,gx:gx,gy:gy,gz:gz,hz:sampleRate,state:status))
                if buffer.count >= 5 { link.sendFrames(buffer); buffer = [] }
            } else { buffer = [] }
        }
    }
    private func send(_ gesture: GestureKind) {
        guard actionID == nil else { actionStatus = "Previous action is still running"; return }
        let event = GestureRequest(revision:configuration.revision,profileID:configuration.selectedProfileID,gesture:gesture)
        actionID = event.id; actionStatus = "Sending…"; actionFailed = false
        link.send(event) { [weak self] result in
            guard let self,self.actionID == event.id else { return }
            self.actionID = nil; self.actionStatus = result.message; self.actionFailed = result.outcome == .failed
            if result.outcome == .failed { WKInterfaceDevice.current().play(.failure) }
        }
        Task { [weak self] in
            try? await Task.sleep(for:.seconds(8))
            guard let self,self.actionID == event.id else { return }
            self.actionID = nil; self.actionFailed = true; self.actionStatus = "Reply timed out · not retried. Check the target."
        }
    }
}
