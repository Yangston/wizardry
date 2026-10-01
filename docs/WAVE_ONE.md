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
- [ ] Double Tap triggers Arm on this hardware. Siri “Start Wizardry” opens a session.
- [ ] Wrist-down pauses and disarms. Raise-to-resume works while Wizardry remains frontmost and the session has not expired. Clock/other-app behavior is not custom-gesture wake.
- [ ] End session and 30-minute expiry prevent automatic resumption.
- [ ] Change profile/settings while armed: old configuration is disarmed and old-revision commands are rejected.

## Live graphs and failures

- [ ] All 12 values respond with plausible units and sample rate.
- [ ] Wrist-down, lost reachability, and app switching mark data stale instead of implying live data.
- [ ] Leaving Live stops its stream subscription; graphs never grow without bound.
- [ ] Turn off the receiver / disconnect Wi-Fi: no delayed action fires when connectivity returns.
- [ ] Test Home offline and Spotify unavailable: errors are visible, no fake success.
- [ ] Check actual reading-session false triggers, watch orientation, battery use, and phone background behavior.

## Evidence boundary

Automated tests cover deterministic state transitions, command/replay checks, receiver behavior, packaging, and native UI navigation. Real paired transport, accessory changes, authorization, and sensing accuracy require the checks above. Leave unchecked until physically tested.
