import SwiftUI
import Charts

struct MotionFeedbackCard: View {
    @ObservedObject var store: PhoneStore
    var body: some View {
        TimelineView(.periodic(from:.now,by:0.25)) { context in
            let frame = store.frames.last
            let snapshot = frame?.control
            let feedback = snapshot?.twistVolume
            let fresh = frame.map {let age = context.date.timeIntervalSince1970-$0.time; return age >= -0.1 && age < 2 && context.date.timeIntervalSince(store.lastTelemetry) < 2} ?? false
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Label("Movement & volume",systemImage:"hand.raised").font(.headline)
                    Spacer()
                    Text(fresh ? "Live" : "Waiting").font(.caption).foregroundStyle(fresh ? .green : .secondary)
                }
                MotionAxisMeter(title:"Twist",degrees:(frame?.roll ?? 0)*180 / .pi)
                MotionAxisMeter(title:"Tilt",degrees:(frame?.pitch ?? 0)*180 / .pi,tint:.cyan)
                MotionAxisMeter(title:"Yaw",degrees:(snapshot?.relativeYaw ?? 0)*180 / .pi,tint:.orange)
                Text("Angles from ready pose · turn past ±55° to enter").font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Label(fresh && snapshot?.phase == .adjustingVolume ? movement(feedback?.angularVelocity ?? 0) : "Twist like a volume knob",
                          systemImage:"dial.low.fill").font(.subheadline.bold())
                    Spacer()
                    if let target = snapshot?.requestedVolume {
                        Text(String(format:"%.1f%%",target*100)).font(.title2.monospacedDigit())
                            .accessibilityIdentifier("live-volume-value")
                    }
                }
                if let target = snapshot?.requestedVolume { ProgressView(value:target).tint(.green) }
                if let feedback {
                    Text(String(format:"Started %.0f%% · change %+.1f percentage points",
                                feedback.startingVolume*100,((snapshot?.requestedVolume ?? feedback.startingVolume)-feedback.startingVolume)*100))
                        .font(.caption).monospacedDigit()
                    Text(String(format:"Knob twist %+.1f° · angular velocity %+.2f rad/s",feedback.twistRadians*180 / .pi,feedback.angularVelocity))
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                Chart {
                    ForEach(store.frames) { sample in
                        if let value = sample.control?.requestedVolume {
                            LineMark(x:.value("Time",Date(timeIntervalSince1970:sample.time)),y:.value("Volume",value*100))
                                .foregroundStyle(by:.value("Volume","Requested"))
                        }
                        if let value = sample.control?.acknowledgedVolume {
                            LineMark(x:.value("Time",Date(timeIntervalSince1970:sample.time)),y:.value("Volume",value*100))
                                .foregroundStyle(by:.value("Volume","Acknowledged"))
                        }
                    }
                    if let feedback {
                        RuleMark(y:.value("Started",feedback.startingVolume*100)).foregroundStyle(.gray)
                            .lineStyle(StrokeStyle(lineWidth:1,dash:[4,4]))
                    }
                }.chartYScale(domain:0...100).chartXAxis(.hidden)
                    .chartForegroundStyleScale(["Requested":Color.green,"Acknowledged":Color.cyan]).frame(height:110)
                    .overlay {
                        if !store.frames.contains(where:{$0.control?.requestedVolume != nil}) {
                            Text("Turn past ±55° after the ready haptic, then twist to adjust").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                if snapshot?.dryRun == true { Text("Dry run · computer audio is unchanged").font(.caption).foregroundStyle(.orange) }
                if !fresh {
                    Text(frame == nil ? "Activate Wizardry on the Watch to see your movements here." : "Showing last received movement, not live readings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(18).background(.white.opacity(0.05),in:RoundedRectangle(cornerRadius:20))
        }
    }
    private func movement(_ velocity: Double) -> String {
        velocity > 0.03 ? "Twisting + · volume up" : velocity < -0.03 ? "Twisting − · volume down" : "Holding volume"
    }
}

struct WatchControlCard: View {
    @ObservedObject var store: PhoneStore
    var body: some View {
        TimelineView(.periodic(from:.now,by:1)) { context in
            let frame = store.frames.last
            let snapshot = frame?.control
            let fresh = frame.map {let age = context.date.timeIntervalSince1970-$0.time; return age >= -0.1 && age < 2 && context.date.timeIntervalSince(store.lastTelemetry) < 2} ?? false
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Label("Live Watch status",systemImage:"applewatch").font(.headline)
                    Spacer()
                    Text(fresh ? "Live" : "Waiting").font(.caption).foregroundStyle(fresh ? .green : .secondary)
                }
                Text(fresh ? snapshot?.phase.title ?? "Watch connected" : "Open Wizardry on your Watch")
                    .font(.title3.bold()).accessibilityIdentifier("watch-control-status")
                if let snapshot {
                    Text("Watch profile: \(snapshot.profileID.capitalized)").font(.caption).foregroundStyle(.secondary)
                    if ["computer","phone"].contains(snapshot.profileID) {
                        yawReadout(snapshot)
                        if let frame { Text(String(format:"Raw sensor yaw %+.0f°",frame.yaw*180 / .pi)).font(.caption2).foregroundStyle(.secondary) }
                    }
                    if let requested = snapshot.requestedVolume {
                        HStack {
                            volumeNumber("Requested",requested)
                            Spacer()
                            if let actual = snapshot.acknowledgedVolume {
                                volumeNumber(snapshot.dryRun ? "Dry run" : "Acknowledged",actual)
                            }
                        }
                    }
                    if snapshot.dryRun { Text("Dry run · computer audio is unchanged").font(.caption).foregroundStyle(.orange) }
                    Label(snapshot.singleTapEnabled ? "Single finger tap enabled" : "Single finger tap needs enrollment",
                          systemImage:snapshot.singleTapEnabled ? "checkmark.circle" : "hand.pinch")
                        .font(.caption).foregroundStyle(snapshot.singleTapEnabled ? .green : .secondary)
                    Text(snapshot.singleTapStatus).font(.caption2).foregroundStyle(.secondary)
                    if let seconds = snapshot.enrollmentRemaining { Text("Recording: \(seconds)s remaining").font(.caption).monospacedDigit() }
                    else if snapshot.armRemaining > 0 { Text("\(snapshot.armRemaining)s to start an action").font(.caption).monospacedDigit() }
                } else {
                    Text("Activate on the Watch to capture the looking pose. Watch mode, yaw change, volume and tap status will appear here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let frame {
                    Text(fresh ? frame.state : "Last Watch message: "+frame.state).font(.caption).foregroundStyle(.secondary)
                    if !fresh { Text("Values above are last received readings, not live.").font(.caption).foregroundStyle(.orange) }
                }
                if let reply = store.lastVolumeReply, reply.outcome == .failed {
                    Text("Volume: "+reply.message).font(.caption).foregroundStyle(.orange)
                }
                if let diagnostic = store.watchDiagnostics {
                    WatchAwakeDiagnosticsView(diagnostic:diagnostic)
                }
            }.padding(18).background(.white.opacity(0.05),in:RoundedRectangle(cornerRadius:20))
        }
    }
    @ViewBuilder private func yawReadout(_ snapshot: WatchControlSnapshot) -> some View {
        if let yaw = snapshot.relativeYaw {
            let degrees = yaw*180 / .pi
            let inZone = abs(degrees) >= 55
            HStack(alignment:.firstTextBaseline) {
                Text("Yaw change from ready pose").font(.caption)
                Spacer()
                Text(String(format:"%+.0f°",degrees)).font(.title2.monospacedDigit()).accessibilityIdentifier("yaw-change-value")
            }
            ProgressView(value:min(1,abs(degrees)/55)).tint(inZone ? .green : .purple)
            Text("Entry at ±55° · no extra hold · then twist like a knob").font(.caption2).foregroundStyle(.secondary)
        } else { Text("Yaw reference: waiting for ready haptic").font(.caption).foregroundStyle(.secondary) }
    }
    private func volumeNumber(_ title: String, _ value: Double) -> some View {
        VStack(alignment:.leading,spacing:2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(Int((value*100).rounded()))%").font(.title2.monospacedDigit())
        }
    }
}

private struct WatchAwakeDiagnosticsView: View {
    let diagnostic: InteractionDiagnosticsSnapshot
    var body: some View {
        DisclosureGroup("Watch awake diagnostics") {
            VStack(alignment:.leading,spacing:6) {
                Text("Recorded \(Date(timeIntervalSince1970:diagnostic.recordedAt),style:.time) · \(diagnostic.scene) / \(diagnostic.application)")
                Text(displayDescription)
                Text(String(format:"Motion %.0f Hz · raw %.0f Hz · sample age %.0f ms · processing %.0f ms",diagnostic.motionHz,diagnostic.rawHz,diagnostic.sampleAgeMS,diagnostic.processingDelayMS))
                Text(String(format:"Maximum sample gap %.0f ms · confirmed %.1f Hz · reply %.0f ms",diagnostic.maximumGapMS,diagnostic.confirmedUpdateHz,diagnostic.roundTripMS))
                Text("\(diagnostic.outstandingUpdates) updates in flight · last stop: \(diagnostic.lastStop?.rawValue ?? "none")")
                Text("Confirmation rate is not measured audio-application rate. Display state still needs physical observation.").foregroundStyle(.secondary)
                ForEach(Array(diagnostic.events.suffix(8).enumerated()),id:\.offset) { item in
                    Text(eventDescription(item.element))
                }
            }.font(.caption2).textSelection(.enabled)
        }
    }
    private var displayDescription: String {
        let luminance = diagnostic.reducedLuminance ? "reduced" : "full"
        let requested = diagnostic.requested ? "yes" : "no"
        let enabled = diagnostic.enabled ? "yes" : "no"
        let rotated = diagnostic.rotated ? "yes" : "no"
        return "Display \(luminance) · autorotation requested \(requested), enabled \(enabled), rotated \(rotated)"
    }
    private func eventDescription(_ event: InteractionDiagnosticEvent) -> String {
        let time = String(format:"%.2f",event.uptime)
        let enabled = event.enabled ? "yes" : "no"
        return "\(time) · \(event.event) · enabled \(enabled)"
    }
}

struct VolumeFlowGuide: View {
    var profileID = "computer"
    private var volume: Bool { ["computer","phone"].contains(profileID) }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Label(volume ? "Activate · Turn · Twist · Lock" : "Activate · Act",systemImage:"sparkles").font(.headline)
            step("1", "Activate", "Wake the Watch and double-touch your fingers to run Activate Wizardry. Hold still looking at it for the ready haptic. Arm on the Watch also works.")
            if volume {
                step("2", "Enter", "Turn away from the ready pose until wrapped yaw reaches 55° in either direction. There is no extra hold; wait for the volume-entry haptic.")
                step("3", "Twist to adjust", profileID == "phone" ? "Keep Wizardry's native volume slider visible on iPhone. Twist your wrist like a knob, starting at the current media volume. Compare requested and actual system readback; the native-slider bridge is experimental." : "Twist your wrist like a volume knob in either direction, starting from the computer's current volume. Hold the twist to keep that level.")
                step("4", "Lock", "Touch thumb and index finger together once after enrollment, or press Lock volume on the Watch. Wait for the locked acknowledgement.")
                Text("Looking back at the Watch or holding still does not stop volume. Lock when done. Leaving the app, interrupted sensing, or the ten-minute interaction limit ends it. Activate again to adjust. Knob direction and custom tap recognition still need physical-watch validation.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                step("2", "Make your wrist action", "Use the selected profile's twist, tilt or shake mapping within the armed window. Return to neutral between actions.")
                Text("Choose Computer or Phone to use live wrist-twist volume control.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(18).background(.purple.opacity(0.1),in:RoundedRectangle(cornerRadius:20))
    }
    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment:.top,spacing:12) {
            Text(number).font(.subheadline.bold()).frame(width:25,height:25)
                .background(.purple.opacity(0.25),in:Circle())
            VStack(alignment:.leading,spacing:3) { Text(title).font(.subheadline.bold()); Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct FingerTapSetupGuide: View {
    var body: some View {
        List {
            Section("On your Watch") {
                Text("Open Wizardry → Learn single finger tap.")
                Text("Keep AssistiveTouch single finger touch at None. Double touch stays assigned to Activate Wizardry.")
                Text("Until enrollment passes, use Lock volume onscreen. The phone displays enrollment and enabled status received from the Watch.")
            }
            Section("Guided recordings") {
                ForEach(TapEnrollment.Stage.allCases.filter {$0 != .complete},id:\.rawValue) { stage in
                    VStack(alignment:.leading,spacing:5) {
                        HStack { Text(title(stage)).font(.headline); Spacer(); Text("\(Int(stage.duration))s").font(.caption).monospacedDigit() }
                        Text(stage.instruction).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical,3)
                }
            }
            Section("Keep the recording visible") {
                Text("Read each step, then start it on the Watch. Keep Wizardry frontmost and the Watch awake. Interrupted recordings must be repeated.")
                Text("Double-touch negative trials preserve a frontmost recording and do not arm controls. Tap recognition is disabled while collecting examples.")
                Text("Your model is enabled only after validation. Recognition accuracy during everyday use still needs testing on your Watch.")
            }
        }.navigationTitle("Learn single tap")
    }
    private func title(_ stage: TapEnrollment.Stage) -> String {
        switch stage {
        case .stationary: return "Stationary taps"
        case .moving: return "Taps while moving"
        case .negatives: return "Other movements"
        case .validationTaps: return "New tap trials"
        case .validationNegatives: return "Five-minute check"
        case .complete: return "Complete"
        }
    }
}
