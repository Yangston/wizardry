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
    private var streamsMotion: Bool { scenePhase == .active && store.configuration.allowsControl && (tab == .control || tab == .live) }
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
        .onChange(of:scenePhase,initial:true) { _,phase in
            store.studio.setForeground(phase == .active)
            if phase != .active { store.suspendPhoneVolume() }
            else { store.phoneVolume.refreshReadiness() }
        }
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
                        Label("iPhone–Watch link: \(link.status)",systemImage:link.reachable ? "applewatch.radiowaves.left.and.right" : "applewatch")
                            .font(.subheadline).foregroundStyle(link.reachable ? .green : .secondary)
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(22)
                        .background(LinearGradient(colors:[.purple.opacity(0.22),.indigo.opacity(0.08)],startPoint:.topLeading,endPoint:.bottomTrailing),in:RoundedRectangle(cornerRadius:24))
                    Picker("Control profile",selection:Binding(get:{store.configuration.selectedProfileID},set:{store.selectProfile($0)})) {
                        ForEach(store.configuration.profiles) { Text($0.name).tag($0.id) }
                    }.pickerStyle(.segmented)
                    if store.configuration.selectedProfileID == "phone" { PhoneVolumeCard(store:store) }
                    WatchConnectionCard(store:store,link:link)
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
                    VolumeFlowGuide(profileID:store.configuration.selectedProfileID)
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
                        }.buttonStyle(.plain).disabled(store.busy || store.studioRecording)
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
                                MappingEditor(draft:binding,home:store.home,profileID:editProfile) { updated in
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
                if ["computer","phone"].contains(editProfile) {
                    Section(editProfile == "phone" ? "Live iPhone volume · experimental" : "Live computer volume") {
                        Text("Turn away from the ready pose until absolute yaw change reaches 55°. Entry needs no extra hold. After the entry haptic, twist your wrist like a volume knob. A learned single finger touch or Lock volume ends adjustment.").font(.caption)
                        Text("Extension takes priority over the discrete mappings above. While adjusting volume, other wrist actions are paused.").font(.caption).foregroundStyle(.secondary)
                        if editProfile == "phone" {
                            Text("Keep Wizardry open on iPhone with its native volume slider visible. Wrist twists change media volume from its current level; no Shortcut is used. Check requested and actual readback values on physical hardware.").font(.caption)
                        }
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
                    Text("This is the time to enter volume mode or start another action. Once volume starts, holding still or rotating back does not end it. Lock when done; leaving the app, interrupted sensing, or the ten-minute interaction limit also ends adjustment.").font(.caption).foregroundStyle(.secondary)
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
    var profileID: String
    var save: (GestureBinding)->Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            Section { Text(draft.gesture.instruction); Toggle("Enabled",isOn:$draft.enabled) }
            Section("Action") {
                Picker("Action",selection:$draft.action) {
                    // Keep an old incompatible value visible without silently
                    // changing it; new choices belong to this selected target.
                    if !draft.action.isAllowed(inProfile:profileID) {
                        Text("\(draft.action.title) · choose a target-compatible action").tag(draft.action)
                    }
                    ForEach(ActionKind.allCases.filter {$0.isAllowed(inProfile:profileID)}) { Text($0.title).tag($0) }
                }.pickerStyle(.navigationLink)
                if !draft.action.isAllowed(inProfile:profileID) {
                    Text("This saved mapping controls another target and cannot execute in this profile. Select a compatible action before saving.")
                        .font(.caption).foregroundStyle(.orange)
                }
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
            .toolbar { ToolbarItem(placement:.confirmationAction) {
                Button("Save") { save(draft); dismiss() }.disabled(!draft.action.isAllowed(inProfile:profileID))
            } }
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
                    if store.configuration.selectedProfileID == "phone" { PhoneVolumeCard(store:store) }
                    ComputerStudioCard(studio:store.studio)
                    MotionFeedbackCard(store:store)
                    WatchControlCard(store:store)
                    SensorChart(title:"User acceleration",unit:"g",frames:store.frames,keys:[\.ax,\.ay,\.az])
                    SensorChart(title:"Rotation rate",unit:"rad/s",frames:store.frames,keys:[\.rx,\.ry,\.rz])
                    SensorChart(title:"Roll / pitch relative · yaw raw",unit:"degrees",frames:store.frames,keys:[\.roll,\.pitch,\.yaw],scale:180 / .pi)
                    SensorChart(title:"Gravity",unit:"g",frames:store.frames,keys:[\.gx,\.gy,\.gz])
                    Text("Volume entry uses a wrapped yaw change of 55° from the ready pose with no extra hold. Once entered, twist like a knob. The graphs keep raw yaw for comparison; roll and pitch are relative to the ready pose. Computer studio can record full sensor data when explicitly enabled.")
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
                    WatchConnectionCard(store:store,link:link)
                    Text("Connect enables Wizardry commands for one selected target. Disconnect stops Wizardry control without unpairing Bluetooth or deleting saved computer credentials.")
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
                    Text("Live volume needs the updated receiver running with --execute. Select Computer on Control, activate on the Watch, turn past 55° of yaw change, then twist like a volume knob. Dry run acknowledges simulated volume only.").font(.caption)
                }
                Section("Computer studio") { ComputerStudioCard(studio:store.studio) }
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
                    PhoneVolumeDetails(controller:store.phoneVolume)
                    Text("Select Phone on Control. Keep Wizardry open on iPhone with this slider visible, activate on the Watch, turn past 55° yaw change, then twist like a knob to change media volume. A learned single touch or Lock volume ends adjustment. No volume Shortcut is needed for this experimental native-slider bridge.").font(.caption)
                    Text("Use Control or Live to watch requested and confirmed volume. iOS does not document a system-volume setter; this bridge needs testing on your physical iPhone and audio output. Leaving Wizardry or changing output stops the session. It does not control ringer volume.").font(.caption).foregroundStyle(.secondary)
                    Text("Existing twist mappings still use Wizardry Volume Up / Wizardry Volume Down Shortcuts: Get Device Details → Current Volume, Calculate ±0.06, then Set Volume. Watch Now Playing also provides Digital Crown volume.").font(.caption)
                }
                Section("Optional · Apple Music") {
                    Button("Allow Apple Music control") {
                        MPMediaLibrary.requestAuthorization { status in Task { @MainActor in musicStatus = status == .authorized ? "Apple Music authorized" : "Apple Music access not granted" } }
                    }
                    if !musicStatus.isEmpty { Text(musicStatus) }
                    Text("Select Apple Music actions in Motions if you use Apple's Music app.").font(.caption)
                }
                Section("Session behavior") {
                    Text("Sessions last up to 30 minutes. Activate while looking at the Watch to capture the yaw reference. Enter an action within the armed window. During live volume, looking back or holding still does not stop it. Lock when done. Leaving Wizardry, interrupted sensing, or the ten-minute interaction limit ends adjustment. Display behavior during stationary holds still needs physical-watch verification.")
                    Text("Discrete commands expire after five seconds; live volume messages expire after one second. Neither is retried or queued for later replay. A haptic confirms recognition. Watch and phone status show requested volume, receiver acknowledgement, dry runs, and errors separately.")
                }.font(.caption)
            }.navigationTitle("Setup")
        }
    }
}

@MainActor
struct NativeVolumeSlider: UIViewRepresentable {
    let controller: PhoneVolumeController
    func makeUIView(context: Context) -> PhoneVolumeView {
        let view = PhoneVolumeView(frame:.zero); view.controller = controller
        return view
    }
    func updateUIView(_ uiView: PhoneVolumeView,context:Context) {}
}

struct PhoneVolumeCard: View {
    @ObservedObject var store: PhoneStore
    var body: some View {
        PhoneVolumeDetails(controller:store.phoneVolume)
    }
}

private struct PhoneVolumeDetails: View {
    @ObservedObject var controller: PhoneVolumeController
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Label("Live iPhone volume · experimental",systemImage:"speaker.wave.2").font(.headline)
            NativeVolumeSlider(controller:controller).frame(height:40).accessibilityIdentifier("phone-volume-slider")
            Label(controller.readinessMessage ?? "Native slider available · writes require system readback",systemImage:controller.readinessMessage == nil ? "checkmark.circle" : "exclamationmark.circle")
                .font(.caption).foregroundStyle(controller.readinessMessage == nil ? .green : .orange)
                .accessibilityIdentifier("phone-volume-readiness")
            if let actual = controller.lastReadback {
                Text(String(format:"System readback %.1f%%",actual*100)).font(.caption.monospacedDigit())
                    .accessibilityIdentifier("phone-volume-readback")
            }
            if let requested = controller.lastRequested {
                Text(String(format:"Requested %.1f%%",requested*100)).font(.caption.monospacedDigit())
                    .accessibilityIdentifier("phone-volume-requested")
            }
            if let failure = controller.lastFailure {
                Text(failure).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("phone-volume-error")
            }
            Button("Check iPhone volume readiness") { controller.refreshReadiness() }.font(.caption)
            Text("Keep this slider visible and Wizardry open. A live session prevents iPhone idle dimming until lock, interruption, or its bounded timeout. Locking the phone or switching apps still stops control. No Shortcut is needed for live volume.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18).background(.purple.opacity(0.1),in:RoundedRectangle(cornerRadius:20))
    }
}

private struct ComputerStudioCard: View {
    @ObservedObject var studio: DesktopStudioRelay
    var body: some View {
        VStack(alignment:.leading,spacing:9) {
            Toggle("Computer studio",isOn:Binding(get:{studio.enabled},set:{studio.setEnabled($0)}))
                .font(.headline).accessibilityIdentifier("computer-studio-toggle")
            Text(studio.status).font(.caption).foregroundStyle(studio.recording ? .orange : .secondary)
                .accessibilityIdentifier("computer-studio-status")
            if studio.enabled {
                Text("Forwarded \(studio.forwardedSamples) samples · dropped \(studio.droppedSamples)")
                    .font(.caption2.monospacedDigit())
            }
            if studio.recording {
                Label("Recording · Watch and test actions disabled",systemImage:"record.circle")
                    .font(.caption.bold()).foregroundStyle(.orange)
            }
            Text("Live sensors, recordings, and mapping edits use the paired computer receiver. This is separate from the command target; Phone can stay selected. Keep Wizardry foreground on iPhone and open the computer studio dashboard.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(14).background(.cyan.opacity(0.08),in:RoundedRectangle(cornerRadius:16))
    }
}

private struct WatchConnectionCard: View {
    @ObservedObject var store: PhoneStore
    @ObservedObject var link: WatchLink
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Label(store.configuration.allowsControl ? "Control target: \(store.configuration.selectedProfile.name)" : "Watch control disconnected",
                  systemImage:store.configuration.allowsControl ? "applewatch.radiowaves.left.and.right" : "applewatch.slash")
                .font(.headline).accessibilityIdentifier("control-target-status")
            Text(store.controlConnectionMessage).font(.caption).foregroundStyle(.secondary)
            if store.configuration.allowsControl {
                Text(link.reachable
                    ? (store.lastWatchRevision == store.configuration.revision ? "Latest selection confirmed on Watch" : "Waiting for Watch to confirm this selection")
                    : "Open Wizardry on your Watch to connect")
                    .font(.caption).foregroundStyle(store.lastWatchRevision == store.configuration.revision && link.reachable ? .green : .orange)
            }
            HStack {
                Button("Connect Watch") { store.connectWatchControl() }
                    .accessibilityIdentifier("connect-watch-control")
                Button("Disconnect",role:.destructive) { store.disconnectWatchControl() }
                    .disabled(!store.configuration.allowsControl).accessibilityIdentifier("disconnect-watch-control")
            }.buttonStyle(.bordered)
            Text("Only the selected target receives commands. Computer pairing can stay saved while Phone is selected.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(14).background(.purple.opacity(0.08),in:RoundedRectangle(cornerRadius:16))
    }
}
