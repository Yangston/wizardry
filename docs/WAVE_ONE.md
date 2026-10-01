# Wave one device checks

The owner reported the original 0.1.0 (2.1) Watch beta working on September 30, 2026. That report does not validate the new 0.2 companion features below. Target hardware reported: Apple Watch Series 12, watchOS 27.0.

## First setup

- [ ] TestFlight installs a launchable iPhone app and the updated Watch app.
- [ ] Open both; iPhone Setup reports the watch connection; profile changes sync.
- [ ] Configure the receiver with a new session token. Verify dry-run acknowledgement before `--execute`.
- [ ] Grant Apple Home access; choose the intended plug for on/off/toggle and a scene for tilt up.
- [ ] Connect Spotify from Setup and start a song in Spotify. Verify play/pause, next, previous. Record the active device and any account/device restrictions.
- [ ] Verify phone volume slider. If using volume gestures, create both named Shortcuts and keep Wizardry foreground; confirm the handoff behavior.

## Watch controls

- [ ] Start a session and calibrate while still. Test vibration.
- [ ] Four alternating twists arm once; they do not also execute a mapped action.
- [ ] Return to neutral, then twist/tilt/shake; verify correct mapping and target acknowledgement.
- [ ] A held pose, small motion, and a single acceleration spike do not repeatedly act.
- [ ] After the armed window expires, action gestures do nothing until wake/Arm.
- [ ] With AssistiveTouch off, standard Double Tap triggers Arm on this hardware. Siri “Start Wizardry” opens the control screen and arms after hold-still calibration.
- [ ] While armed, brief wrist-down/dimming retains the original expiry and neutral position. Actual backgrounding (clock/other app) disarms. Raise-to-resume works while the session has not expired; it does not grant a new armed window.
- [ ] End session and 30-minute expiry prevent automatic resumption.
- [ ] Change profile/settings while armed: old configuration is disarmed and old-revision commands are rejected.

## AssistiveTouch launch (physical devices; unverified until checked)

- [ ] Both updated apps are installed. On iPhone, Shortcuts exposes Wizardry's **Start Wizardry session** action. Create **Activate Wizardry**, enable **Show on Apple Watch**, and verify it syncs to the watch.
- [ ] Running the shortcut on iPhone explains that it must run on Apple Watch; it does not claim to have activated watch sensing.
- [ ] Run the synced shortcut once on the watch and complete any system prompts. Confirm it opens Wizardry and gives one ready haptic after holding still.
- [ ] Enable AssistiveTouch/Hand Gestures and assign Double Clench to Activate Wizardry. Record the watchOS version, available Activation Gesture settings, and actual gesture sequence. If None is unavailable, test the separate AssistiveTouch activation gesture.
- [ ] From the watch face with Wizardry not running, raise and perform the configured gesture. No screen tap or four-twist wake is needed. Record gesture-to-ready latency and repeatability.
- [ ] Repeat from a suspended Wizardry, an active/armed session, the Gesture guide, and Now Playing. Each invocation returns to the control screen and recalibrates once, without duplicate ready haptics or sensor streams.
- [ ] Move continuously during launch: no mapped action occurs, and after ten seconds activation times out. Hold still after retrying: the ready haptic occurs only after calibration and the full configured armed window is available.
- [ ] Repeat the launch-motion test with Require Wake disabled. Launch twists/shakes still cannot execute actions before readiness.
- [ ] During calibration, lower the wrist, navigate to Now Playing, stop the session, change settings from iPhone, or interrupt motion delivery. Verify cancellation and that ordinary wrist raises never replay the old activation. Activate again to recover.
- [ ] After readiness, test twist/tilt/shake, neutral return, cooldown, and armed expiry. Brief dimming retains only the unexpired arm window; manual controls and 30-minute session expiry still work.
- [ ] With iPhone locked, verify actual Spotify/computer/Home action acknowledgement separately from the ready and recognition haptics. Record any target-specific background limitation.
- [ ] Confirm enabling AssistiveTouch disables standard Double Tap and that the setup guide describes the actual system menus. Leave the above checks unchecked until physically tested.

## Armed gestures during dimming (physical devices; unverified until checked)

- [ ] Record watch model, watchOS version, Always On/Low Power settings, and Wrist Flick setting. Compare identical rolls with Wrist Flick on/off if available; distinguish screen dimming from returning to the watch face.
- [ ] Arm, begin a roll, dim the screen, and complete the roll. Confirm one recognition and one target acknowledgement if fresh samples continue. Repeat with tilt and shake; record dropped gestures and actual sample rates rather than assuming watchOS delivers motion while inactive.
- [ ] Raise/lower the wrist repeatedly during the armed window. Confirm countdown and neutral baseline do not reset, and no extra ready haptic occurs.
- [ ] Stay inactive beyond armed expiry, then raise and move. No expired action or queued gesture should execute; a new wake/arm is needed when Require Wake is enabled.
- [ ] Interrupt delivery partway through a roll or shake, then resume before expiry. The remaining armed time is retained, but no partial gesture completes across the interruption; return to neutral before a new action.
- [ ] Press the Crown, switch apps, open Now Playing, stop, or change settings while armed/inactive. Confirm sensing stops and the old armed state cannot return.
- [ ] Disable Require Wake: active gestures still work, but becoming inactive without an explicit arm window stops detection. Manual/Shortcut arming allows only its bounded window while inactive.
- [ ] Compare battery use during repeated armed/dimmed interactions with the previous build. No continuous screen-on or background-runtime capability is requested.

## Live graphs and failures

- [ ] All 12 values respond with plausible units and sample rate.
- [ ] Missing motion delivery, lost reachability, and app switching mark phone graphs stale. Brief dimming only remains live when fresh samples actually continue arriving.
- [ ] Leaving Live stops its stream subscription; graphs never grow without bound.
- [ ] Turn off the receiver / disconnect Wi-Fi: no delayed action fires when connectivity returns.
- [ ] Test Home offline and Spotify unavailable: errors are visible, no fake success.
- [ ] Check actual reading-session false triggers, watch orientation, battery use, and phone background behavior.

## Evidence boundary

Automated tests cover deterministic state transitions, command/replay checks, receiver behavior, packaging, and native UI navigation. Real paired transport, accessory changes, authorization, and sensing accuracy require the checks above. Leave unchecked until physically tested.
