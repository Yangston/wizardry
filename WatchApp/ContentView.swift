import SwiftUI
import WatchKit

struct ContentView: View {
    @ObservedObject var motion: MotionController
    @ObservedObject var link: WatchLink
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack(path:$motion.navigationPath) {
            ScrollView {
                VStack(spacing:12) {
                    Image(systemName:motion.armed ? "sparkles" : "wand.and.stars")
                        .font(.title).foregroundStyle(motion.armed ? .green : .purple)
                    Text(motion.configuration.selectedProfile.name).font(.headline)
                    Text(motion.status).font(.caption).multilineTextAlignment(.center)
                    VolumeStatusView(remote:motion.volume,tapStatus:motion.tapEnrollmentStatus) { motion.endVolume(lock:true) }
                    if #available(watchOS 11.0, *) {
                        armButton.handGestureShortcut(.primaryAction)
                    } else { armButton }
                    Button(motion.sessionActive ? "End session" : "Start 30-min session") {
                        if motion.sessionActive { motion.stop() } else { motion.start() }
                    }.tint(motion.sessionActive ? .red : .purple)
                    Text(motion.actionStatus).font(.caption).foregroundStyle(motion.actionFailed ? .orange : .secondary)
                        .multilineTextAlignment(.center)
                    Text("\(motion.lastGesture) · \(motion.count)").font(.caption2)
                    Text(link.reachable ? "iPhone connected" : "Open Wizardry on iPhone").font(.caption2).foregroundStyle(.secondary)
                    NavigationLink("Now Playing",value:MotionController.Screen.nowPlaying)
                    NavigationLink("Gesture guide",value:MotionController.Screen.guide)
                    NavigationLink("Learn single finger tap",value:MotionController.Screen.enrollment)
                    Button("Test vibration") { motion.testHaptic() }
                    Text(String(format:"Roll %+.0f° · %.0f Hz",motion.rollDegrees,motion.sampleRate))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    Text("Setup, pairing & live graphs are on iPhone.").font(.caption2).multilineTextAlignment(.center)
                }.padding(.horizontal,3)
            }.navigationTitle("Wizardry")
                .navigationDestination(for:MotionController.Screen.self) { screen in
                    switch screen {
                    case .nowPlaying: NowPlayingView()
                    case .guide: guide
                    case .enrollment: TapEnrollmentView(motion:motion)
                    }
                }
        }
        .onChange(of:scenePhase,initial:true) { _,phase in
            switch phase {
            case .active: motion.setScenePhase(.active)
            case .inactive: motion.setScenePhase(.inactive)
            case .background: motion.setScenePhase(.background)
            @unknown default: motion.setScenePhase(.background)
            }
        }
        .onChange(of:motion.navigationPath) { _,_ in motion.navigationChanged() }
    }
    private var armButton: some View {
        Button(motion.armed ? "Armed · \(motion.armRemaining)s" : "Arm now") { motion.arm() }
            .buttonStyle(.borderedProminent).tint(motion.armed ? .green : .purple)
            .disabled(motion.activatingFromShortcut)
    }
    private var guide: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:12) {
                Text("Raise · Activate · Act").font(.headline)
                Text("For touch-free launch, create an iPhone Shortcut named Activate Wizardry using Start Wizardry session. Enable Show on Apple Watch in its details.")
                Text("Your activation setup: AssistiveTouch double finger touch runs Activate Wizardry. Keep its single finger touch assigned to None.")
                Text("Raise your wrist, run the gesture, and hold still until the ready haptic. Then twist, tilt, or shake to act. No four-twist wake is needed after shortcut activation.")
                Text("AssistiveTouch replaces Apple's standard Double Tap. Setup is manual; Wizardry cannot change these system settings. Armed gestures can continue during brief dimming if motion remains available. Leaving Wizardry disarms them.")
                Text("Live volume · experimental").font(.headline)
                Text("Look at the watch while holding still for the ready haptic. Extend your arm until the watch face turns about 90°. Raise or lower your hand in short strokes with pauses. One learned single finger tap locks volume. The Lock button works before enrollment.")
                Text("Volume stops after five seconds without movement, returning to the viewing pose, or interrupted sensing. Activate again to adjust. Height estimation can drift; this is not precise position tracking.")
                Text("Manual control").font(.headline)
                Text("Tap Arm, hold still facing the watch, then make your action. There is no separate twist-to-wake gesture.")
                Text("With AssistiveTouch off, standard Double Tap can press Arm on supported watches. Raise-to-resume requires an active session. Repeat the activation shortcut to open and arm Wizardry again.")
                ForEach(motion.configuration.selectedProfile.bindings.filter(\.enabled)) { binding in
                    Text("\(binding.gesture.title) → \(binding.summary)")
                }
                Text("Dimming keeps only the time left in your armed window. It does not restart the countdown or keep the screen awake. If sensing is interrupted, return to neutral before acting again. Watch settings → Gestures → Wrist Flick → Off may help prevent accidental dismissal.")
            }.font(.caption).padding()
        }.navigationTitle("How to wave")
    }
}

private struct VolumeStatusView: View {
    @ObservedObject var remote: LiveVolumeRemote
    let tapStatus: String
    let lock: () -> Void
    var body: some View {
        if remote.state != .idle {
            VStack(spacing:5) {
                Text(remote.message).font(.caption).multilineTextAlignment(.center)
                if let target = remote.requested { Text("Requested \(Int((target*100).rounded()))%").font(.headline) }
                if let actual = remote.acknowledged {
                    Text("\(remote.dryRun ? "Dry run" : "Acknowledged") \(Int((actual*100).rounded()))%").font(.caption2)
                }
                if remote.state == .adjusting {
                    Text(tapStatus).font(.caption2)
                    Button("Lock volume",action:lock).tint(.green)
                }
            }.padding(6).background(.gray.opacity(0.15),in:RoundedRectangle(cornerRadius:8))
        }
    }
}

private struct TapEnrollmentView: View {
    @ObservedObject var motion: MotionController
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:10) {
                Text("Personalize single tap").font(.headline)
                Text("Keep AssistiveTouch single touch at None. Wear the watch snugly. Recording never executes mapped actions.")
                Text(motion.enrollment.stage.instruction)
                Text(motion.tapEnrollmentStatus).foregroundStyle(.secondary)
                if motion.enrollmentRecording { Text("\(motion.enrollmentRemaining)s remaining").monospacedDigit() }
                else { Button(motion.enrollment.stage == .complete ? "Record again" : "Start this step") { motion.startEnrollmentStep() } }
                Text("Keep Wizardry visible throughout each recording. Five minutes of negative trials are required before single tap is enabled. Interrupted recordings must be repeated.")
                Button("Forget tap learning",role:.destructive) { motion.resetTapEnrollment() }
            }.font(.caption).padding()
        }.navigationTitle("Learn tap")
    }
}
