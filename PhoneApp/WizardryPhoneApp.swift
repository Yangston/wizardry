import SwiftUI
import Charts
import MediaPlayer
import Combine

@main
struct WizardryPhoneApp: App {
    @StateObject private var store = PhoneStore()
    var body: some Scene {
        WindowGroup { PhoneRootView(store:store).tint(.purple).preferredColorScheme(.dark) }
    }
}

struct PhoneRootView: View {
    @ObservedObject var store: PhoneStore
    private enum Tab: Hashable { case control, motions, live, setup }
    @State private var tab = Tab.control
    @Environment(\.scenePhase) private var scenePhase
    private var streamsMotion: Bool { scenePhase == .active && (tab == .control || tab == .live) }
    var body: some View {
        TabView(selection:$tab) {
            ControlDashboard(store:store,link:store.link).tabItem { Label("Control",systemImage:"wand.and.stars") }.tag(Tab.control)
            MotionMappings(store:store).tabItem { Label("Motions",systemImage:"hand.wave") }.tag(Tab.motions)
            LiveMotionView(store:store,link:store.link).tabItem { Label("Live",systemImage:"waveform.path.ecg") }.tag(Tab.live)
            SetupView(store:store,link:store.link,home:store.home,spotify:store.spotify).tabItem { Label("Setup",systemImage:"gearshape") }.tag(Tab.setup)
        }
        .task(id:streamsMotion) {
            guard streamsMotion else { store.link.stopStream(); return }
            while !Task.isCancelled {
                store.link.requestStream()
                do { try await Task.sleep(for:.seconds(10)) } catch { break }
            }
        }
        .onDisappear { store.link.stopStream() }
        .onReceive(store.link.$reachable.removeDuplicates()) { reachable in
            if reachable && streamsMotion { store.link.requestStream() }
        }
    }
}

struct ControlDashboard: View {
    @ObservedObject var store: PhoneStore
    @ObservedObject var link: WatchLink
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    VStack(alignment:.leading,spacing:12) {
                        Image(systemName:"wand.and.stars").font(.system(size:40)).foregroundStyle(.purple)
                        Text("Magic at a wave.").font(.largeTitle.bold())
                        Text("A deliberate motion. Your chosen action.").foregroundStyle(.secondary)
                        Label(link.status,systemImage:link.reachable ? "applewatch.radiowaves.left.and.right" : "applewatch")
                            .font(.subheadline).foregroundStyle(link.reachable ? .green : .secondary)
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(22)
                        .background(LinearGradient(colors:[.purple.opacity(0.22),.indigo.opacity(0.08)],startPoint:.topLeading,endPoint:.bottomTrailing),in:RoundedRectangle(cornerRadius:24))
                    Picker("Control profile",selection:$store.configuration.selectedProfileID) {
                        ForEach(store.configuration.profiles) { Text($0.name).tag($0.id) }
                    }.pickerStyle(.segmented).onChange(of:store.configuration.selectedProfileID) { _,_ in store.saveConfiguration() }
                    MotionFeedbackCard(store:store)
                    WatchControlCard(store:store)
                    DisclosureGroup("All motion axes") {
                        VStack(spacing:16) {
                            SensorChart(title:"User acceleration",unit:"g",frames:store.frames,keys:[\.ax,\.ay,\.az])
                            SensorChart(title:"Rotation rate",unit:"rad/s",frames:store.frames,keys:[\.rx,\.ry,\.rz])
                            SensorChart(title:"Roll / pitch relative · yaw raw",unit:"degrees",frames:store.frames,keys:[\.roll,\.pitch,\.yaw],scale:180 / .pi)
                            SensorChart(title:"Gravity",unit:"g",frames:store.frames,keys:[\.gx,\.gy,\.gz])
                        }.padding(.top,12)
                    }
                    VolumeFlowGuide(computer:store.configuration.selectedProfileID == "computer")
                    NavigationLink { FingerTapSetupGuide() } label: { Label("Single finger tap setup",systemImage:"hand.pinch") }
                    Text("Test discrete actions").font(.title2.bold())
                    Text("These buttons run your mappings now. Home actions need a selected device or scene.").font(.caption).foregroundStyle(.secondary)
                    ForEach(store.configuration.selectedProfile.bindings.filter(\.enabled)) { binding in
                        Button { store.test(binding) } label: {
                            HStack {
                                Image(systemName:"hand.wave.fill").foregroundStyle(.purple).frame(width:32)
                                VStack(alignment:.leading,spacing:4) {
                                    Text(binding.gesture.title).font(.headline)
                                    Text(binding.summary).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName:"play.circle.fill").font(.title2)
                            }.padding().background(.white.opacity(0.05),in:RoundedRectangle(cornerRadius:16))
                        }.buttonStyle(.plain).disabled(store.busy)
                    }
                    Text("Recent actions").font(.title2.bold())
                    if store.history.isEmpty { Text("Acknowledged actions and errors appear here.").foregroundStyle(.secondary) }
                    ForEach(store.history) { event in
                        HStack(alignment:.top) {
                            Image(systemName:event.result.outcome == .failed ? "exclamationmark.circle" : "checkmark.circle")
                                .foregroundStyle(event.result.outcome == .failed ? .orange : .green)
                            VStack(alignment:.leading) {
                                Text(event.title).font(.subheadline.bold())
                                Text(event.result.message).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(); Text(event.time,style:.time).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }.padding(20)
            }.navigationTitle("Wizardry")
        }
    }
}

struct MotionMappings: View {
    @ObservedObject var store: PhoneStore
    @State private var editProfile = "computer"
    var body: some View {
        NavigationStack {
            Form {
                Section("Profile to edit") {
                    Picker("Profile",selection:$editProfile) {
                        ForEach(store.configuration.profiles) { Text($0.name).tag($0.id) }
                    }.pickerStyle(.segmented)
                    Text("Editing a profile does not select it. Select the active profile on Control.").font(.caption)
                }
                if let index = store.configuration.profiles.firstIndex(where:{$0.id == editProfile}) {
                    Section("Other wrist actions") {
                        ForEach(store.configuration.profiles[index].bindings) { binding in
                            NavigationLink {
                                MappingEditor(draft:binding,home:store.home) { updated in
                                    if let b = store.configuration.profiles[index].bindings.firstIndex(where:{$0.id == updated.id}) {
                                        store.configuration.profiles[index].bindings[b] = updated; store.saveConfiguration()
                                    }
                                }
                            } label: {
                                VStack(alignment:.leading,spacing:5) {
                                    Text(binding.gesture.title)
                                    Text(binding.enabled ? binding.summary : "Disabled").font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical,4)
                            }
                        }
                    }
                }
                if editProfile == "computer" {
                    Section("Live computer volume") {
                        Text("Extend your arm so z / yaw changes about 90° from the ready pose. After the entry haptic, raise/lower vertically in short strokes with pauses. A learned single finger touch or Lock volume ends adjustment.").font(.caption)
                        Text("Extension takes priority over the discrete mappings above. While adjusting volume, other wrist actions are paused.").font(.caption).foregroundStyle(.secondary)
                        NavigationLink("Single finger tap setup") { FingerTapSetupGuide() }
                    }
                }
                Section("Activation and discrete-action sensitivity") {
                    Text("Double finger touch runs Activate Wizardry. Hold still looking at the Watch for the ready haptic, or use Arm on the Watch.").font(.caption)
                    VStack(alignment:.leading) {
                        Text("Discrete twist / tilt angle: \(Int(store.configuration.threshold * 180 / .pi))°")
                        Slider(value:$store.configuration.threshold,in:0.45...1.2,step:0.05,onEditingChanged: { if !$0 { store.saveConfiguration() } })
                    }
                    Stepper("Start an action within \(Int(store.configuration.armSeconds)) seconds",value:$store.configuration.armSeconds,in:3...20,step:1)
                        .onChange(of:store.configuration.armSeconds) { _,_ in store.saveConfiguration() }
                    Text("This is the time to enter volume mode or start another action. Once volume starts, it stays active until lock, five seconds without movement, returning to the viewing yaw, or interrupted sensing.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Ideas to try") {
                    Label("Reading: a twist turns on your lamp; a shake pauses Spotify.",systemImage:"book")
                    Label("Movie night: a tilt activates your Home scene and its selected lights.",systemImage:"film")
                    Label("Presentation: map tilts to next / previous slide on your computer.",systemImage:"rectangle.on.rectangle")
                    Label("Find your phone: map a motion to the locator chime.",systemImage:"iphone.radiowaves.left.and.right")
                }.font(.subheadline)
            }.navigationTitle("Motions")
        }
    }
}

struct MappingEditor: View {
    @State var draft: GestureBinding
    @ObservedObject var home: HomeController
    var save: (GestureBinding)->Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            Section { Text(draft.gesture.instruction); Toggle("Enabled",isOn:$draft.enabled) }
            Section("Action") {
                Picker("Action",selection:$draft.action) {
                    ForEach(ActionKind.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.navigationLink)
                if draft.action == .shortcut {
                    TextField("Exact Shortcut name",text:$draft.shortcutName).autocorrectionDisabled()
                    Text("Requires Wizardry open on iPhone. iOS opens Shortcuts; completion is not reported. For volume, create Wizardry Volume Up and Wizardry Volume Down with Get Device Details → Current Volume, Calculate ±0.06, and Set Volume.").font(.caption)
                }
                if draft.action.isHomePower || draft.action == .homeScene {
                    Picker("Target",selection:Binding(get:{draft.targetID},set:{ id in
                        draft.targetID = id
                        let target = (draft.action == .homeScene ? home.scenes : home.devices).first { $0.id == id }
                        draft.homeID = target?.homeID ?? ""; draft.targetName = target?.name ?? ""
                    })) {
                        Text("Choose a target").tag("")
                        ForEach(draft.action == .homeScene ? home.scenes : home.devices) { Text($0.name).tag($0.id) }
                    }
                    Text(home.status).font(.caption)
                    Text("Existing Matter plugs in Apple Home appear here. Create a Reading or Movie Night scene in Home, then select it.").font(.caption)
                }
                if [.phonePlayPause,.phoneNext,.phonePrevious].contains(draft.action) {
                    Text("Apple Music only. Use the Spotify actions for Spotify playback.").font(.caption)
                }
                if [.spotifyVolumeUp,.spotifyVolumeDown].contains(draft.action) {
                    Text("Only works when the active Spotify Connect device allows remote volume. Spotify on iPhone may not; use volume Shortcuts with Wizardry open, or Watch Now Playing.").font(.caption)
                }
            }
        }.navigationTitle(draft.gesture.title)
            .onChange(of:draft.action) { _,_ in draft.targetID = ""; draft.homeID = ""; draft.targetName = "" }
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Save") { save(draft); dismiss() } } }
    }
}

struct LiveMotionView: View {
    @ObservedObject var store: PhoneStore
    @ObservedObject var link: WatchLink
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    TimelineView(.periodic(from:.now,by:1)) { context in
                        let live = context.date.timeIntervalSince(store.lastTelemetry) < 2
                        VStack(alignment:.leading,spacing:6) {
                            Label(live ? "Live from Apple Watch" : "Waiting for live motion",systemImage:live ? "dot.radiowaves.left.and.right" : "pause.circle")
                                .foregroundStyle(live ? .green : .orange).font(.headline)
                            Text(live ? "\(Int(store.frames.last?.hz ?? 0)) Hz capture · up to 20 Hz display · local transfer" : "Activate Wizardry on the Watch and hold still for the ready haptic. Keep Control or Live open on your phone.")
                                .font(.caption).foregroundStyle(.secondary)
                            if !live && !store.frames.isEmpty { Text("Graphs show the last received data, not current readings.").font(.caption).foregroundStyle(.orange) }
                            if let sample = store.frames.last { Text("Watch: \(sample.state)").font(.caption) }
                        }
                    }
                    MotionFeedbackCard(store:store)
                    WatchControlCard(store:store)
                    SensorChart(title:"User acceleration",unit:"g",frames:store.frames,keys:[\.ax,\.ay,\.az])
                    SensorChart(title:"Rotation rate",unit:"rad/s",frames:store.frames,keys:[\.rx,\.ry,\.rz])
                    SensorChart(title:"Roll / pitch relative · yaw raw",unit:"degrees",frames:store.frames,keys:[\.roll,\.pitch,\.yaw],scale:180 / .pi)
                    SensorChart(title:"Gravity",unit:"g",frames:store.frames,keys:[\.gx,\.gy,\.gz])
                    Text("Arm extension uses the wrapped change in z / yaw from the ready haptic, shown above. The graph keeps raw yaw for comparison; roll and pitch are relative to the ready pose. Data stays on your devices and is not saved as a recording.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationTitle("Live motion")
                .toolbar { Button("Clear") { store.clearFrames() } }
        }
    }
}

struct SensorChart: View {
    let title: String
    let unit: String
    let frames: [MotionFrame]
    let keys: [KeyPath<MotionFrame,Double>]
    var scale = 1.0
    private let names = ["x / roll","y / pitch","z / yaw"]
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { Text(title).font(.headline); Spacer(); Text(unit).foregroundStyle(.secondary).font(.caption) }
            Chart {
                ForEach(frames) { frame in
                    ForEach(0..<3,id:\.self) { index in
                        LineMark(x:.value("Time",Date(timeIntervalSince1970:frame.time)),y:.value(unit,frame[keyPath:keys[index]]*scale))
                            .foregroundStyle(by:.value("Axis",names[index]))
                    }
                }
            }.chartForegroundStyleScale([names[0]:Color.purple,names[1]:Color.cyan,names[2]:Color.orange])
                .chartXAxis(.hidden).frame(height:150)
                .overlay { if frames.isEmpty { Text("No samples yet").foregroundStyle(.secondary) } }
            if let frame = frames.last {
                HStack {
                    ForEach(0..<3,id:\.self) { i in
                        Text(String(format:"%+.2f",frame[keyPath:keys[i]]*scale)).monospacedDigit().frame(maxWidth:.infinity)
                    }
                }.font(.caption)
            }
        }.padding(16).background(.white.opacity(0.05),in:RoundedRectangle(cornerRadius:18))
    }
}

struct SetupView: View {
    @ObservedObject var store: PhoneStore
    @ObservedObject var link: WatchLink
    @ObservedObject var home: HomeController
    @ObservedObject var spotify: SpotifyController
    @State private var musicStatus = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("1 · Apple Watch") {
                    Label(link.status,systemImage:"applewatch")
                    Text("Wizardry uses your existing iPhone–Watch pairing. Install both apps, open Wizardry on each, then sync. No separate watch pairing code is needed.")
                    Button("Sync settings to watch") { store.saveConfiguration() }
                    Text("Raise your wrist and double-touch your fingers to run Activate Wizardry. Hold still looking at the Watch for the ready haptic. Arm on the Watch also works. Keep AssistiveTouch single touch at None.")
                        .font(.caption)
                    NavigationLink("Single finger tap setup") { FingerTapSetupGuide() }
                }
                Section("2 · Computer receiver") {
                    TextField("http://192.168.x.x:8765",text:$store.endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Receiver pairing token",text:$store.pairingToken).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save pairing & test connection") { Task { await store.pairComputer() } }
                        .disabled(store.pairingBusy)
                    Text(store.pairingStatus).font(.caption)
                    Link("Receiver installation instructions",destination:URL(string:"https://github.com/Yangston/wizardry/tree/main/receiver")!)
                    Text("The phone sends commands to the receiver on your local network. Tokens are stored in the iPhone Keychain and are never sent to the watch. Start with dry run. HTTP is intended for a trusted private network.").font(.caption)
                    Text("Live volume needs the updated receiver running with --execute. Select Computer on Control, activate on the Watch, then extend to about 90° of yaw change. Dry run acknowledges simulated volume only.").font(.caption)
                }
                Section("3 · Apple Home") {
                    Button("Connect / refresh Apple Home") { store.connectHome() }
                    Text(home.status)
                    Text("Select each plug, light, or scene under Motions. Your existing Apple Home Matter pairing is reused. Wizardry only lists power controls for lights, outlets, and switches.").font(.caption)
                }
                Section("4 · Spotify") {
                    Text(spotify.status).font(.subheadline)
                    Button(spotify.connected ? "Reconnect Spotify" : "Connect Spotify") { spotify.login() }
                    if spotify.connected { Button("Disconnect Spotify",role:.destructive) { spotify.disconnect() } }
                    if spotify.clientID.isEmpty { Text("Spotify developer setup is still needed for this beta. Expand Advanced to configure it.").font(.caption).foregroundStyle(.orange) }
                    DisclosureGroup("Advanced connection settings") {
                        TextField("Spotify Developer Client ID",text:$spotify.clientID).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("Spotify Premium and a developer app are required. Add the iOS bundle com.yangston.wizardry and redirect below; allowlist your account. Use only the public Client ID, never a client secret.").font(.caption)
                        Text(SpotifyController.redirect).font(.caption.monospaced()).textSelection(.enabled)
                        Link("Spotify developer setup",destination:URL(string:"https://developer.spotify.com/dashboard")!)
                    }
                    Text("Start Spotify on the phone or Connect device you want to control. Commands target the active player. Phone profile uses Spotify for play/pause and tracks. Remote volume depends on the player's supported controls.").font(.caption)
                }
                Section("Phone volume") {
                    NativeVolumeSlider().frame(height:40)
                    Text("Native media volume works with Spotify. Gesture volume on iPhone uses two user-created Shortcuts while Wizardry is open. Create Wizardry Volume Up / Wizardry Volume Down: Get Device Details → Current Volume, Calculate ±0.06, then Set Volume. The watch's Now Playing screen also provides native playback and Digital Crown volume.").font(.caption)
                }
                Section("Optional · Apple Music") {
                    Button("Allow Apple Music control") {
                        MPMediaLibrary.requestAuthorization { status in Task { @MainActor in musicStatus = status == .authorized ? "Apple Music authorized" : "Apple Music access not granted" } }
                    }
                    if !musicStatus.isEmpty { Text(musicStatus) }
                    Text("Select Apple Music actions in Motions if you use Apple's Music app.").font(.caption)
                }
                Section("Session behavior") {
                    Text("Sessions last up to 30 minutes. Activate while looking at the Watch to capture the yaw reference. Enter an action within the armed window. Live volume then remains active until lock, five seconds without movement, return to the viewing yaw, or interrupted sensing. Fresh motion is required during dimming; leaving Wizardry disarms controls.")
                    Text("Discrete commands expire after five seconds; live volume messages expire after one second. Neither is retried or queued for later replay. A haptic confirms recognition. Watch and phone status show requested volume, receiver acknowledgement, dry runs, and errors separately.")
                }.font(.caption)
            }.navigationTitle("Setup")
        }
    }
}

struct NativeVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { MPVolumeView(frame:.zero) }
    func updateUIView(_ uiView: MPVolumeView,context:Context) {}
}
