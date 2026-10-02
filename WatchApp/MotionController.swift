import Combine
import CoreMotion
import Foundation
import WatchKit

@MainActor
final class MotionController: ObservableObject {
    enum Screen: Hashable { case nowPlaying, guide, enrollment }
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
    @Published private(set) var pitchDegrees = 0.0
    @Published private(set) var yawDegrees = 0.0
    @Published private(set) var volumeMotion: VolumeMotionFeedback?
    @Published private(set) var sampleRate = 0.0
    @Published private(set) var count = 0
    @Published private(set) var lastGesture = "None yet"
    @Published private(set) var actionStatus = "Set up actions on your iPhone"
    @Published private(set) var actionFailed = false
    let link = WatchLink()
    private let manager = CMMotionManager()
    private let interactionRuntime = InteractionRuntime(makeDriver: { WatchInteractionAutorotation() })
    lazy var volume = LiveVolumeRemote(link:link)
    @Published private(set) var enrollment = TapEnrollment()
    @Published private(set) var enrollmentRecording = false
    @Published private(set) var enrollmentRemaining = 0
    @Published private(set) var tapEnrollmentStatus = "Single tap disabled - enroll first"
    private var tapModel: FingerTapModel?
    private var capture: MotionCapture?
    private var lastMotion: CapturedMotion?
    private var lastAccepted: Double?
    private var lastDelivery = 0.0
    private var arbiter = ExtensionArbiter()
    private var viewingAngles: (Double,Double)?
    private var extending = false
    private var tracker = VerticalVolumeTracker()
    private var volumeClaimed = false
    private var tapFrozen = false
    private var pendingMotion: [CapturedMotion] = []
    private var viewingSince: Double?
    private var ignoreTapsUntil = 0.0
    private var enrollmentDeadline = 0.0
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
        interactionRuntime.interrupted = { [weak self] message in
            self?.pause(message)
        }
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
        if let data = UserDefaults.standard.data(forKey:"fingerTapModel"),
           let model = try? JSONDecoder().decode(FingerTapModel.self,from:data), model.isValid, model.validated {
            tapModel = model; tapEnrollmentStatus = "Personalized single tap enabled"
        }
        volume.didBegin = { [weak self] in
            guard let self, self.volumeClaimed, let motion = self.lastMotion, let level = self.volume.acknowledged else { return }
            self.tracker.begin(volume:level,acceleration:motion.acceleration,gravity:motion.gravity,time:motion.time)
            self.volumeMotion = self.tracker.feedback
            self.haptic(.click)
        }
        volume.didFinish = { [weak self] in
            guard let self, self.volumeClaimed else { return }
            self.interactionRuntime.stop()
            self.gestures.reset(); self.armed = false; self.armRemaining = 0
            self.status = self.volume.message
            if self.volume.state == .locked { self.haptic(.success) }
        }
        configureEngine()
    }
    private func configureEngine() {
        interactionRuntime.stop()
        armExpiryTask?.cancel(); armExpiryTask = nil
        if volume.ownsMotion { volume.finish(lock:false) }
        volumeClaimed = false; arbiter = ExtensionArbiter(); tapFrozen = false; viewingSince = nil; pendingMotion = []
        viewingAngles = nil; extending = false; yawDegrees = 0; rollDegrees = 0; pitchDegrees = 0; volumeMotion = nil
        gestures.reset()
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
                if self.interactionRuntime.expireIfNeeded() { continue }
                let now = ProcessInfo.processInfo.systemUptime
                if self.volume.ownsMotion && now-self.lastDelivery > 0.25 { self.endVolume(lock:false) }
                if self.enrollmentRecording {
                    self.enrollmentRemaining = max(0,Int(ceil(self.enrollmentDeadline-now)))
                    if now-self.lastDelivery > 0.25 { self.cancelEnrollment("Recording interrupted - repeat this step") }
                }
            }
        }
        resume()
    }
    func resume() {
        guard gestures.phase == .active, navigationPath.last != .nowPlaying, sessionActive, !running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if activation.expire(at:now) { stop("Activation timed out · activate again"); return }
        guard let end = sessionEnd, Date() < end else { stop("Session expired — start again"); return }
        guard manager.isDeviceMotionAvailable, manager.isAccelerometerAvailable else { stop("Motion unavailable on this device"); return }
        configureEngine(); firstSample = nil; samples = 0; lastDisplay = 0; buffer = []; sampleRate = 0
        generation += 1; let capture = generation
        activation.beginCapture(at:now)
        running = true
        status = activation.isPending ? "Hold still - preparing gestures" : "Activate Wizardry or tap Arm"
        lastAccepted = nil; lastMotion = nil
        let worker = MotionCapture(); self.capture = worker
        worker.reset(model:tapModel)
        worker.motionDelivered = { [weak self] sample in
            Task { @MainActor in
                guard let self, self.running, self.generation == capture else { return }
                self.consume(sample)
            }
        }
        worker.tapDelivered = { [weak self] output in
            Task { @MainActor in
                guard let self, self.running, self.generation == capture,
                      ProcessInfo.processInfo.systemUptime >= self.ignoreTapsUntil else { return }
                self.tapFrozen = output.frozen
                if output.observation?.recognized == true, let motion = self.lastMotion {
                    self.pendingMotion = []; self.tracker.freeze(at:motion.time)
                }
                if output.event != nil, self.volumeClaimed, self.volume.state == .adjusting { self.endVolume(lock:true) }
            }
        }
        worker.enrollmentDelivered = { [weak self] learning,complete in
            Task { @MainActor in
                guard let self, self.generation == capture, self.enrollmentRecording else { return }
                self.enrollmentRecording = false; self.enrollment = learning
                if !complete { self.tapEnrollmentStatus = "Recording interrupted or below 70 Hz - repeat this step" }
                else if learning.stage == .complete {
                    self.tapEnrollmentStatus = learning.report
                    if let model = learning.model, model.isValid, model.validated {
                        self.tapModel = model
                        if let data = try? JSONEncoder().encode(model) { UserDefaults.standard.set(data,forKey:"fingerTapModel") }
                    }
                } else { self.tapEnrollmentStatus = "Step recorded - prepare for the next step" }
                self.capture?.reset(model:self.tapModel)
            }
        }
        manager.deviceMotionUpdateInterval = 1.0/100
        manager.accelerometerUpdateInterval = 1.0/100
        manager.startDeviceMotionUpdates(to:worker.queue) { [weak self] motion,error in
            if let motion { worker.accept(motion) }
            else { Task { @MainActor in
                guard let self, self.generation == capture else { return }
                self.stop(error?.localizedDescription ?? "Motion unavailable")
            } }
        }
        manager.startAccelerometerUpdates(to:worker.queue) { [weak self] sample,error in
            if let sample { worker.accept(sample) }
            else { Task { @MainActor in
                guard let self, self.generation == capture else { return }
                self.stop(error?.localizedDescription ?? "Raw acceleration unavailable")
            } }
        }
    }

    func pause(_ message: String = "Paused · raise wrist to resume") {
        cancelShortcutActivation()
        suspendCapture(message)
    }
    private func suspendCapture(_ message: String) {
        cancelEnrollment("Recording interrupted - repeat this step")
        capture?.cancelEnrollment()
        generation += 1; manager.stopDeviceMotionUpdates(); manager.stopAccelerometerUpdates(); running = false; buffer = []; configureEngine()
        if sessionActive { status = message }
    }
    func setScenePhase(_ phase: ForegroundGestureSession.Phase) {
        let now = ProcessInfo.processInfo.systemUptime
        let canContinue = gestures.transition(to:phase,at:now) || (phase == .inactive && volume.ownsMotion)
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
                // Autorotation remains enabled only for this bounded interaction.
                // Every sample is still checked for age and ordering.
                updateArmDisplay(at:now)
            } else {
                suspendCapture(activation.isPending ? "Opening control · hold still" : "Paused · raise wrist to resume")
            }
        }
    }
    func navigationChanged() {
        if navigationPath.last == .nowPlaying { pause("Paused for Now Playing") }
        else if navigationPath.last == .enrollment {
            interactionRuntime.stop()
            cancelShortcutActivation(); endVolume(lock:false); gestures.reset(); armed = false
            if !sessionActive { start() } else { resume() }
        } else {
            cancelEnrollment("Enrollment paused"); capture?.reset(model:tapModel); resume()
        }
    }
    func activateFromShortcut() {
        // Enrollment deliberately includes double touches as negative trials.
        // AssistiveTouch invokes this same shortcut for them. While a recording
        // is already frontmost, clear pending control input without throwing away
        // the recording or calibrating/arming a control interaction.
        if navigationPath.last == .enrollment, enrollmentRecording, running, gestures.phase == .active {
            interactionRuntime.stop()
            cancelShortcutActivation(); gestures.reset(); armed = false; armRemaining = 0
            // Capture is training-only (no model). Preserve complete candidate
            // windows so both halves of a negative double touch are recorded.
            tapFrozen = false; pendingMotion = []
            return
        }
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
        activateFromShortcut()
    }
    func endVolume(lock: Bool) {
        guard volumeClaimed else { return }
        interactionRuntime.stop()
        volume.finish(lock:lock); gestures.reset(); armed = false; armRemaining = 0
        armExpiryTask?.cancel(); status = volume.message
    }
    func startEnrollmentStep() {
        guard gestures.phase == .active, !enrollmentRecording else { return }
        if enrollment.stage == .complete { enrollment = TapEnrollment() }
        if !sessionActive { start() }
        guard running else { return }
        interactionRuntime.stop()
        endVolume(lock:false); gestures.reset(); armed = false
        enrollmentRecording = true
        enrollmentDeadline = ProcessInfo.processInfo.systemUptime+enrollment.stage.duration
        enrollmentRemaining = Int(enrollment.stage.duration)
        tapEnrollmentStatus = "Recording - " + enrollment.stage.instruction
        capture?.startEnrollmentStage(enrollment,at:ProcessInfo.processInfo.systemUptime)
    }
    private func cancelEnrollment(_ message: String) {
        if enrollmentRecording { enrollmentRecording = false; tapEnrollmentStatus = message }
        capture?.cancelEnrollment()
    }
    func resetTapEnrollment() {
        cancelEnrollment("Single tap disabled - enroll again"); tapModel = nil; enrollment = TapEnrollment()
        UserDefaults.standard.removeObject(forKey:"fingerTapModel"); capture?.reset(model:nil)
        tapEnrollmentStatus = "Single tap disabled - enroll first"
    }
    private func haptic(_ type: WKHapticType) {
        let now = ProcessInfo.processInfo.systemUptime
        ignoreTapsUntil = now+0.35; tapFrozen = false
        capture?.suppressHaptic(at:now)
        WKInterfaceDevice.current().play(type)
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
            self.interactionRuntime.stop()
            if self.gestures.phase == .inactive {
                self.pause("Armed window ended · raise wrist to resume")
            } else {
                self.updateArmDisplay(at:now)
            }
        }
    }
    private func updateArmDisplay(at now: Double) {
        armed = gestures.engine.isArmed(at:now)
        if !armed && !volume.ownsMotion { interactionRuntime.stop() }
        armRemaining = armed ? max(0,Int(ceil(gestures.engine.armedUntil-now))) : 0
        if volumeClaimed { status = volume.message }
        else if activation.isPending { status = "Hold still · preparing gestures" }
        else if armed { status = "Ready · yaw \(Int(yawDegrees.rounded()))° · \(armRemaining)s" }
        else { status = "Activate Wizardry or tap Arm" }
    }
    func testHaptic() { haptic(.click) }
    private func consume(_ motion: CapturedMotion) {
        let time = motion.time, now = ProcessInfo.processInfo.systemUptime
        guard let end = sessionEnd, Date() < end else { stop("Session expired - start again"); return }
        if interactionRuntime.expireIfNeeded() { return }
        guard [time,motion.roll,motion.pitch,motion.yaw,now].allSatisfy(\.isFinite),
              motion.acceleration.isFinite, motion.rotation.isFinite, motion.gravity.isFinite,
              motion.attitude.normal != nil, time <= now, now-time <= 0.25,
              lastAccepted.map({time > $0}) ?? true else {
            if volumeClaimed { endVolume(lock:false) }
            gestures.engine.interruptMotion(at:now); arbiter.interruptMotion(); return
        }
        if let previous = lastAccepted, time-previous > 0.25 {
            if volumeClaimed { endVolume(lock:false) }
            gestures.engine.interruptMotion(at:now)
            arbiter.interruptMotion()
            cancelEnrollment("Recording interrupted - repeat this step")
        }
        lastAccepted = time; lastDelivery = now; lastMotion = motion
        if firstSample == nil { firstSample = time }
        samples += 1
        let acceleration = motion.acceleration.length, rotation = motion.rotation.length
        var gestureEvent: GestureEngine.Event?
        if navigationPath.last == .enrollment {
            // Enrollment never executes computer or other mapped commands.
        } else if activation.isPending {
            switch activation.update(roll:motion.roll,pitch:motion.pitch,acceleration:acceleration,
                                     rotationRate:rotation,sampleTime:time,now:now) {
            case .ready:
                cancelShortcutActivation()
                gestures.calibrateAndArm(roll:motion.roll,pitch:motion.pitch,sampleTime:time,readyTime:now)
                arbiter.calibrate(yaw:motion.yaw); viewingAngles = (motion.roll,motion.pitch)
                capture?.reset(model:tapModel)
                // Enable autorotation after calibration, before the ready haptic.
                // A new activation owns a fresh, bounded interaction window.
                guard interactionRuntime.start(until:gestures.engine.armedUntil,
                                               canStart:gestures.phase == .active) else { return }
                scheduleArmExpiry(); armed = true; status = "Ready - extend arm or make a gesture"
                haptic(.success)
            case .timedOut: stop("Activation timed out - activate again"); return
            case .invalidMotion: stop("Invalid motion - activate again"); return
            case nil: break
            }
        } else if volumeClaimed {
            if volume.state == .adjusting {
                if now < ignoreTapsUntil || arbiter.isViewing(yaw:motion.yaw) {
                    tracker.freeze(at:time); pendingMotion = []
                } else if tapFrozen {
                    pendingMotion.append(motion)
                    if pendingMotion.count > 80 { pendingMotion = []; endVolume(lock:false) }
                } else {
                    for frame in pendingMotion + [motion] {
                        _ = tracker.update(acceleration:frame.acceleration,gravity:frame.gravity,
                                           rotation:frame.rotation.length,time:frame.time)
                    }
                    pendingMotion = []; volume.setTarget(tracker.target)
                }
                if arbiter.isViewing(yaw:motion.yaw) {
                    if viewingSince == nil { viewingSince = time }
                    if time-(viewingSince ?? time) >= 0.25 { endVolume(lock:false) }
                } else { viewingSince = nil }
                if time-tracker.lastMovement >= 5 { endVolume(lock:false) }
            }
        } else {
            gestures.expireArm(at:now)
            guard gestures.allowsMotion(at:now) else { pause("Activate again to resume"); return }
            var suppress = volume.ownsMotion
            if configuration.supportsLiveVolume, gestures.engine.isArmed(at:now) {
                let route = arbiter.update(yaw:motion.yaw,acceleration:acceleration,rotation:rotation,time:time)
                extending = route == .transition && abs(arbiter.relativeYaw) >= 25 * .pi/180
                suppress = suppress || route != .legacy
                if route == .enterVolume, !volume.ownsMotion {
                    volumeClaimed = true; armExpiryTask?.cancel(); armed = false; armRemaining = 0
                    gestures.reset(); tapFrozen = false; viewingSince = nil
                    // Keep autorotation through this live interaction, bounded
                    // by the outer session and a ten-minute interaction limit.
                    guard interactionRuntime.continueThroughVolume(
                        until:now + end.timeIntervalSinceNow) else { return }
                    volume.begin(revision:configuration.revision,phone:configuration.selectedProfileID == "phone")
                }
            }
            if !volumeClaimed {
                let result = gestures.update(roll:motion.roll,pitch:motion.pitch,acceleration:acceleration,
                                             sampleTime:time,now:now,suppressActions:suppress)
                if result.accepted { gestureEvent = result.event }
            }
        }
        if let event = gestureEvent, case .action(let gesture) = event,
           let binding = configuration.selectedProfile.bindings.first(where:{$0.gesture == gesture && $0.enabled}) {
            count += 1; lastGesture = gesture.title; haptic(.click)
            if binding.action == .haptic { actionStatus = "Haptic only"; actionFailed = false }
            else { send(gesture) }
        }
        if time-lastDisplay >= 0.05 {
            yawDegrees = (arbiter.yawOffset(motion.yaw) ?? 0)*180 / .pi
            updateArmDisplay(at:now)
            rollDegrees = viewingAngles.map {ExtensionArbiter.offset(motion.roll,from:$0.0)*180 / .pi} ?? 0
            pitchDegrees = viewingAngles.map {ExtensionArbiter.offset(motion.pitch,from:$0.1)*180 / .pi} ?? 0
            if volumeMotion != nil { volumeMotion = tracker.feedback }
            let elapsed = time-(firstSample ?? time); sampleRate = elapsed > 0 ? Double(samples-1)/elapsed : 0
            lastDisplay = time
            if Date().timeIntervalSince1970 < link.streamUntil {
                let a = motion.acceleration, r = motion.rotation, g = motion.gravity
                buffer.append(.init(time:Date().timeIntervalSince1970,
                                    roll:viewingAngles.map {ExtensionArbiter.offset(motion.roll,from:$0.0)} ?? 0,
                                    pitch:viewingAngles.map {ExtensionArbiter.offset(motion.pitch,from:$0.1)} ?? 0,
                                    yaw:motion.yaw,ax:a.x,ay:a.y,az:a.z,
                                    rx:r.x,ry:r.y,rz:r.z,gx:g.x,gy:g.y,gz:g.z,hz:sampleRate,state:status,
                                    control:controlSnapshot(yaw:motion.yaw)))
                // Small live batches avoid the previous half-second graph delay.
                if buffer.count >= 2 { link.sendFrames(buffer); buffer = [] }
            } else { buffer = [] }
        }
    }
    private func controlSnapshot(yaw: Double) -> WatchControlSnapshot {
        let phase: WatchControlSnapshot.Phase
        if navigationPath.last == .enrollment { phase = .enrolling }
        else if activation.isPending { phase = .calibrating }
        else if volumeClaimed {
            switch volume.state {
            case .beginning: phase = .volumeStarting
            case .adjusting: phase = .adjustingVolume
            case .locking: phase = .lockingVolume
            case .locked: phase = .locked
            case .failed: phase = .failed
            default: phase = .stopped
            }
        } else if armed { phase = extending ? .extending : .armed }
        else { phase = .unarmed }
        return .init(phase:phase,profileID:configuration.selectedProfileID,relativeYaw:arbiter.yawOffset(yaw),
                     requestedVolume:volumeClaimed ? volume.requested : nil,
                     acknowledgedVolume:volumeClaimed ? volume.acknowledged : nil,dryRun:volumeClaimed && volume.dryRun,
                     singleTapEnabled:tapModel?.validated == true,singleTapStatus:tapEnrollmentStatus,
                     armRemaining:armRemaining,enrollmentRemaining:enrollmentRecording ? enrollmentRemaining : nil,
                     volumeMotion:volumeClaimed ? volumeMotion : nil)
    }
    private func send(_ gesture: GestureKind) {
        guard actionID == nil else { actionStatus = "Previous action is still running"; return }
        let event = GestureRequest(revision:configuration.revision,profileID:configuration.selectedProfileID,gesture:gesture)
        actionID = event.id; actionStatus = "Sending…"; actionFailed = false
        link.send(event) { [weak self] result in
            guard let self,self.actionID == event.id else { return }
            self.actionID = nil; self.actionStatus = result.message; self.actionFailed = result.outcome == .failed
            if result.outcome == .failed { self.haptic(.failure) }
        }
        Task { [weak self] in
            try? await Task.sleep(for:.seconds(8))
            guard let self,self.actionID == event.id else { return }
            self.actionID = nil; self.actionFailed = true; self.actionStatus = "Reply timed out · not retried. Check the target."
        }
    }
}
