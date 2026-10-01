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
    private var gestures = ForegroundGestureSession()
    private var activation = ShortcutActivation()
    private var activationTimeoutTask: Task<Void,Never>?
    private var armExpiryTask: Task<Void,Never>?
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
                else if self.gestures.phase != .active { self.pause("Settings changed · raise wrist to resume") }
                else { self.configureEngine() }
                self.actionID = nil
            }
            self.actionStatus = "Synced: \(config.selectedProfile.name)"; self.actionFailed = false
        }
        configureEngine()
    }
    private func configureEngine() {
        armExpiryTask?.cancel(); armExpiryTask = nil
        gestures.reset()
        gestures.engine.requireWake = configuration.requireWake
        gestures.engine.threshold = configuration.threshold
        gestures.engine.armSeconds = configuration.armSeconds
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
        guard gestures.phase == .active, navigationPath.last != .nowPlaying, sessionActive, !running else { return }
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
    func setScenePhase(_ phase: ForegroundGestureSession.Phase) {
        let now = ProcessInfo.processInfo.systemUptime
        let canContinue = gestures.transition(to:phase,at:now)
        if phase == .active {
            resume()
            if running { updateArmDisplay(at:now) }
        }
        else {
            // A Shortcut may arrive before the first active scene notification.
            // Preserve that waiting request, but cancel an unfinished calibration.
            activation.leaveForeground()
            if !activation.isPending { cancelShortcutActivation() }
            if canContinue && running {
                // Keep the same subscription, baseline, and deadline while inactive.
                // watchOS may still suspend delivery; every sample is checked for age.
                updateArmDisplay(at:now)
            } else {
                suspendCapture(activation.isPending ? "Opening control · hold still" : "Paused · raise wrist to resume")
            }
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
        guard gestures.phase == .active else { return }
        cancelShortcutActivation()
        if !sessionActive { start() }
        guard running else { return }
        gestures.engine.arm(time:ProcessInfo.processInfo.systemUptime)
        scheduleArmExpiry(); armed = true; status = "Return to neutral, then act"
        WKInterfaceDevice.current().play(.success)
    }
    private func scheduleArmExpiry() {
        armExpiryTask?.cancel()
        let deadline = gestures.engine.armedUntil
        armExpiryTask = Task { [weak self] in
            // Sleep may be delayed by system suspension. Delivery and scene-change
            // paths also check this absolute deadline before allowing any action.
            while !Task.isCancelled {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 { break }
                do { try await Task.sleep(for:.seconds(remaining)) } catch { return }
            }
            guard !Task.isCancelled, let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.gestures.expireArm(at:now)
            if self.gestures.phase == .inactive {
                self.pause("Armed window ended · raise wrist to resume")
            } else {
                self.updateArmDisplay(at:now)
            }
        }
    }
    private func updateArmDisplay(at now: Double) {
        armed = gestures.engine.isArmed(at:now)
        armRemaining = armed ? max(0,Int(ceil(gestures.engine.armedUntil-now))) : 0
        if activation.isPending { status = "Hold still · preparing gestures" }
        else if armed { status = "Armed · \(armRemaining)s" }
        else { status = configuration.requireWake ? "Double twist to wake" : "Ready for a gesture" }
    }
    func testHaptic() { WKInterfaceDevice.current().play(.click) }
    private func consume(time: Double,roll: Double,pitch: Double,yaw: Double,ax: Double,ay: Double,az: Double,rx: Double,ry: Double,rz: Double,gx: Double,gy: Double,gz: Double) {
        guard let end = sessionEnd, Date() < end else { stop("Session expired — start again"); return }
        let acceleration = sqrt(ax*ax+ay*ay+az*az)
        let now = ProcessInfo.processInfo.systemUptime
        gestures.expireArm(at:now)
        guard gestures.allowsMotion(at:now) else {
            pause("Paused · raise wrist to resume")
            return
        }
        var gestureEvent: GestureEngine.Event?
        if activation.isPending {
            // Never feed launch motion to the action recognizer, even with wake disabled.
            let event = activation.update(roll:roll,pitch:pitch,acceleration:acceleration,
                                          rotationRate:sqrt(rx*rx+ry*ry+rz*rz),sampleTime:time,
                                          now:now)
            switch event {
            case .ready:
                cancelShortcutActivation()
                gestures.calibrateAndArm(roll:roll,pitch:pitch,sampleTime:time,readyTime:now)
                scheduleArmExpiry()
                armed = true; armRemaining = Int(ceil(configuration.armSeconds))
                status = "Ready · make a gesture"
                WKInterfaceDevice.current().play(.success)
            case .timedOut: stop("Activation timed out · activate again"); return
            case .invalidMotion: stop("Motion unavailable · activate again"); return
            case nil: break
            }
            // The calibration helper also rejects stale delivery. Do not publish
            // those buffered frames as fresh live telemetry while waiting.
            guard time <= now, now - time <= 0.25 else { buffer = []; sampleRate = 0; return }
        } else {
            let result = gestures.update(roll:roll,pitch:pitch,acceleration:acceleration,sampleTime:time,now:now)
            guard result.accepted else {
                buffer = []; sampleRate = 0; firstSample = nil; samples = 0
                if !gestures.allowsMotion(at:now) { pause("Motion interrupted · raise wrist to resume") }
                else { updateArmDisplay(at:now) }
                return
            }
            gestureEvent = result.event
        }
        if firstSample == nil { firstSample = time }
        samples += 1
        if let event = gestureEvent {
            switch event {
            case .woke:
                scheduleArmExpiry()
                WKInterfaceDevice.current().play(.success); status = "Return to neutral, then act"
            case .action(let gesture):
                guard let binding = configuration.selectedProfile.bindings.first(where:{$0.gesture == gesture && $0.enabled}) else { return }
                count += 1; lastGesture = gesture.title; WKInterfaceDevice.current().play(.click)
                if binding.action == .haptic { actionStatus = "Haptic only"; actionFailed = false }
                else { send(gesture) }
            }
        }
        if time-lastDisplay >= 0.1 {
            updateArmDisplay(at:now)
            rollDegrees = gestures.engine.relativeRoll*180 / .pi
            let elapsed = time-(firstSample ?? time); sampleRate = elapsed > 0 ? Double(samples-1)/elapsed : 0
            lastDisplay = time
            if Date().timeIntervalSince1970 < link.streamUntil {
                buffer.append(.init(time:Date().timeIntervalSince1970,roll:gestures.engine.relativeRoll,pitch:gestures.engine.relativePitch,yaw:yaw,
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
