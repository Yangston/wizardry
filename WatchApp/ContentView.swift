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
                Text("On your watch, enable Settings → Accessibility → AssistiveTouch → Hand Gestures. Assign Double Clench to the Activate Wizardry shortcut.")
                Text("Set Activation Gesture to None if available. Otherwise, perform your AssistiveTouch activation gesture first, then Double Clench to run the shortcut.")
                Text("Raise your wrist, run the gesture, and hold still until the ready haptic. Then twist, tilt, or shake to act. No four-twist wake is needed after shortcut activation.")
                Text("AssistiveTouch replaces Apple's standard Double Tap. Setup is manual; Wizardry cannot change these system settings. Armed gestures can continue during brief dimming if motion remains available. Leaving Wizardry disarms them.")
                Text("Manual control").font(.headline)
                Text("Start a session. Raise your wrist with Wizardry frontmost. Twist + / − / + / − within 2.5 seconds, return to neutral, then make your action.")
                Text("With AssistiveTouch off, standard Double Tap can press Arm on supported watches. Raise-to-resume requires an active session. Repeat the activation shortcut to open and arm Wizardry again.")
                ForEach(motion.configuration.selectedProfile.bindings.filter(\.enabled)) { binding in
                    Text("\(binding.gesture.title) → \(binding.summary)")
                }
                Text("Dimming keeps only the time left in your armed window. It does not restart the countdown or keep the screen awake. If sensing is interrupted, return to neutral before acting again. Watch settings → Gestures → Wrist Flick → Off may help prevent accidental dismissal.")
            }.font(.caption).padding()
        }.navigationTitle("How to wave")
    }
}
