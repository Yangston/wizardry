# Wave one device checks

The owner reported the original 0.1.0 (2.1) Watch beta working on September 30, 2026. That report does not validate the new 0.2 companion features below. Target hardware reported: Apple Watch Series 12, watchOS 27.0.

The user subsequently reported that rotation works in **0.2.0 (15.1)**, including the previously problematic backward tilt. Build **16.1** added stationary-hold behavior, but its physical hold test is not recorded as passed. These are not completed pose, output-timing, knob, recording, or battery checks.

## First setup

- [ ] TestFlight installs a launchable iPhone app and the updated Watch app.
- [ ] Open both; explicitly connect Computer or Phone on the Watch, or use iPhone Connect Watch. Connection/target changes receive acknowledgement, and profile changes sync. All Watch commands are relayed by iPhone.
- [ ] Disconnect stops Wizardry control without unpairing devices or deleting computer credentials. Disconnected commands cannot execute. Reconnect and activate afresh. Switching target invalidates the prior session, and no action reaches both outputs.
- [ ] Update both apps and restart the updated receiver using its saved pairing token. Verify authenticated transport-v2 capability and dry-run acknowledgement before `--execute`.
- [ ] Grant Apple Home access; choose the intended plug for on/off/toggle and a scene for tilt up.
- [ ] Connect Spotify from Setup and start a song in Spotify. Verify play/pause, next, previous. Record the active device and any account/device restrictions.
- [ ] Verify the plain native iPhone volume view loads. Connect Phone, keep its slider visible, and test 55° yaw entry, signed twist-knob adjustment, and lock against real system-volume readback. The removed native-view subclass does not by itself prove control works. Check speaker/headphones independently. See [iPhone acceptance checks](LIVE_VOLUME.md#live-iphone-volume-experimental).
- [ ] If using the existing discrete volume twist mappings, create both named Shortcuts and keep Wizardry foreground; confirm the handoff behavior.

## Watch controls

- [ ] Start a session and calibrate while still. Test vibration.
- [ ] Activate using the AssistiveTouch double finger touch or Arm button. Hold still for one ready haptic; twisting without explicit activation cannot arm.
- [ ] Return to neutral, then twist/tilt/shake; verify correct mapping and target acknowledgement.
- [ ] A held pose, small motion, and a single acceleration spike do not repeatedly act.
- [ ] After the armed window expires, action gestures do nothing until fresh Shortcut/Arm activation.
- [ ] From several ready headings, yaw to ±54.9° without entering, then cross ±55° while moving. Volume enters on the first fresh sample without settling. Larger extension angles still qualify. Gaps, duplicates, and invalid samples cannot trigger entry.
- [ ] Begin at several actual volume levels. Small positive twists increase volume and negative twists decrease it; 90° changes the target by 50 percentage points. Crossing ±180° does not jump. Reversing at 0%/100% responds immediately, and raising/lowering alone is not the control input.
- [ ] With AssistiveTouch off, standard Double Tap triggers Arm on this hardware. Siri “Start Wizardry” opens the control screen and arms after hold-still calibration.
- [ ] While armed, brief wrist-down/dimming retains the original expiry and neutral position. Actual backgrounding (clock/other app) disarms. Raise-to-resume works while the session has not expired; it does not grant a new armed window.
- [ ] End session and 30-minute expiry prevent automatic resumption.
- [ ] Change profile/settings while armed: old configuration is disarmed and old-revision commands are rejected.

## AssistiveTouch launch (physical devices; unverified until checked)

- [ ] Both updated apps are installed. On iPhone, Shortcuts exposes Wizardry's **Start Wizardry session** action. Create **Activate Wizardry**, enable **Show on Apple Watch**, and verify it syncs to the watch.
- [ ] Running the shortcut on iPhone explains that it must run on Apple Watch; it does not claim to have activated watch sensing.
- [ ] Run the synced shortcut once on the watch and complete any system prompts. Confirm it opens Wizardry and gives one ready haptic after holding still.
- [ ] Enable AssistiveTouch/Hand Gestures and assign double finger touch to Activate Wizardry. Record the watchOS version, available Activation Gesture settings, and actual gesture sequence. If None is unavailable, test the separate AssistiveTouch activation gesture.
- [ ] From the watch face with Wizardry not running, raise and perform the configured gesture. No screen tap or four-twist wake is needed. Record gesture-to-ready latency and repeatability.
- [ ] Repeat from a suspended Wizardry, an active/armed session, the Gesture guide, and Now Playing. Each invocation returns to the control screen and recalibrates once, without duplicate ready haptics or sensor streams.
- [ ] Move continuously during launch: no mapped action occurs, and after ten seconds activation times out. Hold still after retrying: the ready haptic occurs only after calibration and the full configured armed window is available.
- [ ] Repeat launch while deliberately twisting/shaking. No actions may execute before hold-still readiness, and twisting without explicit activation must never arm.
- [ ] During calibration, verify an inactive transition retains the same valid autorotation lease and only fresh samples count toward hold-still readiness. Backgrounding, Now Playing, stopping, changed settings, or sensor failure cancels activation; ordinary wrist raises never replay it. A sample gap cannot count as uninterrupted calibration time.
- [ ] After readiness, test twist/tilt/shake, neutral return, cooldown, and armed expiry. Brief dimming retains only the unexpired arm window; manual controls and 30-minute session expiry still work.
- [ ] With iPhone locked, verify actual Spotify/computer/Home action acknowledgement separately from the ready and recognition haptics. Record any target-specific background limitation.
- [ ] Confirm enabling AssistiveTouch disables standard Double Tap and that the setup guide describes the actual system menus. Leave the above checks unchecked until physically tested.

## Physical display and bounded interaction (unverified until checked)

The release requirement is that the physical display remains awake during movement, backward tilt, and stationary pauses within a bounded live-volume interaction. Dimming or a black screen with continuing control is a failure of that requirement. The inactive-state checks below test safe behavior if dimming occurs; they do not count as display-awake acceptance.

- [ ] Record watch model, watchOS version, Always On/Low Power settings, and Wrist Flick setting. Compare identical rolls with Wrist Flick on/off if available; distinguish screen dimming from returning to the watch face.
- [ ] Arm, begin a roll, dim the screen, and complete the roll. Confirm one recognition and one target acknowledgement if fresh samples continue. Repeat with tilt and shake; record dropped gestures and actual sample rates rather than assuming watchOS delivers motion while inactive.
- [ ] Raise/lower the wrist repeatedly during the armed window. Confirm countdown and neutral baseline do not reset, and no extra ready haptic occurs.
- [ ] Stay inactive beyond armed expiry, then raise and move. No expired action or queued gesture should execute; fresh shortcut/button activation is required.
- [ ] Interrupt delivery partway through a roll or shake, then resume before expiry. The remaining armed time is retained, but no partial gesture completes across the interruption; return to neutral before a new action.
- [ ] Press the Crown, switch apps, open Now Playing, stop, or change settings while armed/inactive. Confirm sensing stops and the old armed state cannot return.
- [ ] Without explicit arming, movement in either active or inactive scenes cannot act. Manual/Shortcut arming allows only its bounded window while inactive. Live volume preserves a healthy stationary session until manual lock, explicit interruption, sensing/transport failure, or its existing cap.
- [ ] In the device console, inspect `InteractionAutorotation` and `InteractionDiagnostics`. Verify enablement when foreground calibration starts, continuous ownership through readiness, and release at armed expiry. Idle screens and enrollment must not enable autorotation. Repeat activation; expiry from the previous activation must not disable the new interaction.
- [ ] On Series 12/watchOS 27.0, test **both Computer and Phone** outputs with three 15-second small positive/negative twist trials in each condition: sideways, palm-up, backward tilt, and crossing the viewing yaw. The physical display must remain awake throughout; crossing the viewing yaw must not end volume. Observe the display; autorotation readback alone is insufficient. Repeat without a debugger.
- [ ] On **both Computer and Phone**, hold still for 10–30 seconds during live volume. Verify the physical display stays awake, volume remains constant, and movement resumes adjustment without reactivation. Confirm an unchanged-volume heartbeat every second and no stationary auto-exit. Repeat without an attached debugger; broader pose/battery checks remain separate.
- [ ] During those trials, measure actual successful applied/read-back output timestamps, avoiding saturation at 0%/100%. Acceptance targets are at least 30 applied updates/s and p95 inter-update gap no greater than 60 ms while the target changes. Record motion/raw delivery rates, median/worst movement latency, and Watch confirmed acknowledgement Hz separately; acknowledgement arrivals do not measure applied-output timing. These targets are unverified until measured.
- [ ] Enter live volume near armed expiry. Autorotation remains enabled through adjustment, stationary holds, and the bounded final acknowledgement without toggling off/on. Lock requests the final end; failure, Now Playing, enrollment, backgrounding, explicit stop, and settings changes release the lease. Verify the ten-minute cap from calibration and the outer-session cap without automatic renewal from motion or heartbeats.
- [ ] After final acknowledgement, stop, or expiry, rotate and lower the wrist. Ordinary display behavior returns, no expired command executes, and a wrist raise does not enable autorotation until fresh activation. Verify interface flips do not alter wrapped-yaw entry or signed knob direction.
- [ ] Inspect **Awake diagnostics** on Watch and iPhone: scene/application state, autorotation request/readback, reduced luminance, delivered raw/device-motion Hz, sample age, processing delay, confirmed acknowledgement Hz, round-trip time, outstanding updates, and typed stop reason agree with observed events. Relaunch the Watch app and verify the bounded history of at most 48 events preserves the last stop evidence without credentials.
- [ ] Compare battery use during repeated armed interactions with the previous build. This build requests no extended runtime, background mode, artificial workout, or silent audio. Record whether autorotation actually prevents sleeping in each physical pose.

## Live graphs and failures

- [ ] Sensor values respond with plausible units/rates; knob feedback uses signed twist degrees and degrees/second, not height or inertial travel. Starting, requested, and acknowledged volume remain distinct.
- [ ] Transport v2 supports changing targets with no more than four outstanding Watch updates; the phone executes one write with one newest waiting target. Superseded replies must not move acknowledged-volume displays or claim that a target was applied.
- [ ] Lock during a full update window. The priority final end takes the next phone write after the executing request, closes the session, and prevents old updates from changing the final volume. A lost final reply must show stopped/unconfirmed rather than locked.
- [ ] Test against an old phone or receiver: smooth adjustment must report the required update instead of silently using unsupported transport. Legacy 20 Hz clients remain accepted by the new receiver.
- [ ] Missing motion delivery, lost reachability, and app switching mark phone graphs stale. Brief dimming only remains live when fresh samples actually continue arriving.
- [ ] Leaving Live stops its stream subscription; graphs never grow without bound.
- [ ] Turn off the receiver / disconnect Wi-Fi: no delayed action fires when connectivity returns.
- [ ] Stop request delivery and confirm the six-second phone/receiver missing-request watchdog still closes the backend session. Holding still with healthy one-second heartbeats must not trigger this watchdog; fresh-sample and transport-failure checks remain enforced.
- [ ] Test Home offline and Spotify unavailable: errors are visible, no fake success.
- [ ] Check actual reading-session false triggers, watch orientation, battery use, and phone background behavior.

## Computer studio and movement recording (unverified until checked)

- [ ] Enable Computer studio explicitly on the foreground iPhone and keep Wizardry visible on Watch. Open the receiver's Live sensors page and Start sensors. The dashboard shows fresh sensor values and reported rates; disabling Studio or losing the relay marks them stale.
- [ ] Keep Phone as the command target while monitoring on the computer. Monitoring does not change the selected output, enable two command targets, or expose pairing credentials to the dashboard.
- [ ] Create a named movement and choose Record example. Preparing requires holding still; movement instructions appear only after the Watch confirms recording. No pre-confirmation or ordinary monitoring samples enter the saved take.
- [ ] During recording, twist/tilt/shake and invoke Activate Wizardry. No mapped command, knob update, or accidental control activation executes; capture remains an explicit action-disabled mode.
- [ ] Stop & save persists the named take locally with timestamps and quality information. Cancel discards it. Test the 60-second limit, dropped samples, stale telemetry, iPhone backgrounding, and leaving the Watch app; interrupted/partial takes are identified and no expired samples replay.
- [ ] Map a custom recorded movement to an action label. It is stored for later training and remains untrained/inactive; performing that movement does not invoke a new recognizer.
- [ ] Separately edit an existing Computer/Phone discrete mapping in Map movements. Only the iPhone's expected-revision acknowledgement confirms application. A stale revision or disconnected phone is reported rather than silently overwriting newer settings. Home targets remain configured on iPhone.
- [ ] Verify sensor recordings live only in the local receiver data folder and are absent from pairing-token/error output. Ordinary phone graph telemetry remains bounded and separate from saved recording takes.

## Evidence boundary

Automated tests cover deterministic state transitions, command/replay checks, receiver behavior, packaging, and native UI navigation. Real paired transport, accessory changes, authorization, and sensing accuracy require the checks above. Leave unchecked until physically tested.


Live computer volume, learned single-touch setup, and physical acceptance checks are described in [LIVE_VOLUME.md](LIVE_VOLUME.md). Keep AssistiveTouch single finger touch assigned to **None**; double touch runs **Activate Wizardry**. The separate twist-to-wake mechanism has been removed.
