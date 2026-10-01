import SwiftUI
import WatchKit

struct ContentView: View {
    @ObservedObject var motion: MotionController
    @ObservedObject var link: WatchLink
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
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
                    NavigationLink("Now Playing") {
                        NowPlayingView().onAppear { motion.pause("Paused for Now Playing") }.onDisappear { motion.resume() }
                    }
                    NavigationLink("Gesture guide") { guide }
                    Button("Test vibration") { motion.testHaptic() }
                    Text(String(format:"Roll %+.0f° · %.0f Hz",motion.rollDegrees,motion.sampleRate))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    Text("Setup, pairing & live graphs are on iPhone.").font(.caption2).multilineTextAlignment(.center)
                }.padding(.horizontal,3)
            }.navigationTitle("Wizardry")
        }
        .onChange(of:scenePhase) { _,phase in if phase == .active { motion.resume() } else { motion.pause() } }
    }
    private var armButton: some View {
        Button(motion.armed ? "Armed · \(motion.armRemaining)s" : "Arm now") { motion.arm() }
            .buttonStyle(.borderedProminent).tint(motion.armed ? .green : .purple)
    }
    private var guide: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:12) {
                Text("Raise · Wake · Act").font(.headline)
                Text("Start a session. Raise your wrist with Wizardry frontmost. Twist + / − / + / − within 2.5 seconds, return to neutral, then make your action.")
                Text("Double Tap can press Arm on supported watches. Raise-to-resume requires an active session. A motion cannot wake a closed app.")
                ForEach(motion.configuration.selectedProfile.bindings.filter(\.enabled)) { binding in
                    Text("\(binding.gesture.title) → \(binding.summary)")
                }
                Text("Sensors pause on wrist-down. For a reading session, set Return to Clock to After 1 hour in Watch settings.")
            }.font(.caption).padding()
        }.navigationTitle("How to wave")
    }
}
