import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var motion = MotionController()
    @StateObject private var commands = CommandClient()
    @AppStorage("serverURL") private var serverURL = ""
    @State private var token = "" // Session-only; never baked into the app or stored in defaults.
    @State private var sendGestures = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Image(systemName: "wand.and.stars").font(.title).foregroundStyle(.purple)
                    Text(motion.status).font(.caption).multilineTextAlignment(.center)
                    Button(motion.running ? "Stop" : "Start") {
                        if motion.running { motion.stop() } else { motion.start() }
                    }.buttonStyle(.borderedProminent).tint(motion.running ? .red : .purple)
                    Text(String(format: "%+.0f°", motion.rollDegrees))
                        .font(.system(.largeTitle, design: .rounded)).monospacedDigit()
                    Text("\(motion.lastGesture) · \(motion.count)").font(.caption)
                    Button("Test vibration") { motion.testHaptic() }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Acceleration · g").foregroundStyle(.secondary)
                        Text(motion.acceleration).monospacedDigit()
                        Text("Rotation · rad/s").foregroundStyle(.secondary)
                        Text(motion.rotation).monospacedDigit()
                        Text(String(format: "Samples: %.0f Hz", motion.sampleRate))
                    }.font(.system(size: 11, design: .monospaced))
                    NavigationLink("Computer control") { controlSettings }
                    Text(buildLabel).font(.caption2).foregroundStyle(.secondary)
                }.padding(.horizontal, 4)
            }.navigationTitle("Wizardry")
        }
        .onAppear { bindGestureCommands() }
        .onChange(of: sendGestures) { _, _ in bindGestureCommands() }
        .onChange(of: serverURL) { _, _ in bindGestureCommands() }
        .onChange(of: token) { _, _ in bindGestureCommands() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                motion.stop("Paused — tap Start to resume")
                sendGestures = false
            }
        }
    }

    private var controlSettings: some View {
        Form {
            TextField("http://PC-IP:8765", text: $serverURL)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Pairing token", text: $token)
            Text("Token lasts until app closes. Use your paired phone keyboard to enter it.")
                .font(.caption2)
            Button("Send test command") { send("ping") }.disabled(commands.busy)
            Toggle("Gestures control volume", isOn: $sendGestures)
            Text("Rotate +: volume up. Rotate −: volume down. Start motion on the main screen.")
                .font(.caption2)
            Text(commands.status).font(.caption).accessibilityIdentifier("commandStatus")
        }.navigationTitle("Computer")
    }

    private func bindGestureCommands() {
        motion.onGesture = { gesture in
            guard sendGestures else { return }
            send(gesture == .positive ? "volume_up" : "volume_down")
        }
    }

    private func send(_ command: String) {
        Task { await commands.send(command, endpoint: serverURL, token: token) }
    }

    private var buildLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(version) (\(build))"
    }
}
