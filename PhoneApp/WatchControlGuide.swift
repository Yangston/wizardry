import SwiftUI

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
                    if snapshot.profileID == "computer" {
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
                    Text("Receiver: "+reply.message).font(.caption).foregroundStyle(.orange)
                }
            }.padding(18).background(.white.opacity(0.05),in:RoundedRectangle(cornerRadius:20))
        }
    }
    @ViewBuilder private func yawReadout(_ snapshot: WatchControlSnapshot) -> some View {
        if let yaw = snapshot.relativeYaw {
            let degrees = yaw*180 / .pi
            let inZone = (70...110).contains(abs(degrees))
            HStack(alignment:.firstTextBaseline) {
                Text("Yaw change from ready pose").font(.caption)
                Spacer()
                Text(String(format:"%+.0f°",degrees)).font(.title2.monospacedDigit()).accessibilityIdentifier("yaw-change-value")
            }
            ProgressView(value:min(1,abs(degrees)/90)).tint(inZone ? .green : .purple)
            Text("Aim for ±90° · entry zone 70–110° · hold briefly").font(.caption2).foregroundStyle(.secondary)
        } else { Text("Yaw reference: waiting for ready haptic").font(.caption).foregroundStyle(.secondary) }
    }
    private func volumeNumber(_ title: String, _ value: Double) -> some View {
        VStack(alignment:.leading,spacing:2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(Int((value*100).rounded()))%").font(.title2.monospacedDigit())
        }
    }
}

struct VolumeFlowGuide: View {
    var computer = true
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Label(computer ? "Activate · Extend · Adjust · Lock" : "Activate · Act",systemImage:"sparkles").font(.headline)
            step("1", "Activate", "Wake the Watch and double-touch your fingers to run Activate Wizardry. Hold still looking at it for the ready haptic. Arm on the Watch also works.")
            if computer {
                step("2", "Extend", "Extend your arm so z / yaw changes about 90° from the ready pose. Hold briefly until the volume-entry haptic.")
                step("3", "Adjust live", "Raise your hand to increase computer volume; lower it to decrease. Use short vertical strokes with pauses. Start at the computer's current volume.")
                step("4", "Lock", "Touch thumb and index finger together once after enrollment, or press Lock volume on the Watch. Wait for the locked acknowledgement.")
                Text("Volume stops after five seconds without movement, returning to the viewing yaw, or interrupted sensing. Activate again to adjust. Height tracking and custom tap recognition are experimental.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                step("2", "Make your wrist action", "Use the selected profile's twist, tilt or shake mapping within the armed window. Return to neutral between actions.")
                Text("Choose Computer to use live arm-height volume control.").font(.caption).foregroundStyle(.secondary)
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
