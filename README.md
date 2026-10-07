# Wizardry: Magic at a Wave

A native iPhone and Apple Watch gesture remote, developed on Windows and built with Xcode in GitHub Actions.

## Wave one · 0.2

- **iPhone companion:** set up your computer, connect Apple Home and Spotify, select a profile, and edit every gesture-to-action mapping.
- **Watch:** explicit Computer/Phone connect and disconnect controls, touch-free AssistiveTouch/Shortcut launch with hold-still calibration, a 30-minute control session, experimental twist-knob volume and learned single-touch locking, an eight-second armed window, Double Tap on supported watches, and native Now Playing controls.
- **Live motion:** opening screens show twist, tilt, yaw and volume feedback. iPhone Control / Live include a requested-versus-acknowledged volume graph and all sensor axes. Requested 100 Hz capture (actual hardware rate displayed), up to 20 Hz display, roughly 100 ms telemetry batches, bounded local buffers, and explicit stale status.
- **Computer:** Windows volume, mute, play/pause, track navigation, and next/previous slide or page. The receiver dashboard includes volume feedback, **Live sensors**, **Record movements**, and **Map movements** (`--no-ui` for console-only use). Named recordings and custom mapping labels prepare examples for later training; they do not install a trained recognizer.
- **Phone:** Spotify playback on the active player, Apple Music controls, a locator chime, native volume slider, and named Shortcuts.
- **Apple Home:** select existing lights, switches, Matter plugs, or scenes. No separate Matter commissioning is required.

## Install and set up

Install the latest Wizardry beta using TestFlight on the iPhone paired with your Watch. Version 0.2 adds a real iPhone app to the existing watch app. Open Wizardry on both devices; Apple's existing pairing links them automatically.

In **Setup** on iPhone:

1. Sync settings to the watch.
2. Pair the optional [computer receiver](receiver/README.md) using its LAN address and token.
3. Connect Apple Home, then choose your devices and scenes in **Motions**.
4. Connect Spotify Premium. A Spotify developer client must be configured; the app uses PKCE without a client secret. Start Spotify on your intended playback device first.
5. Select the intended control target and connect Watch control. Computer and Phone can also be selected on the Watch. Only one command target is active; all Watch commands go through the paired iPhone. Editing a profile does not activate it. Disconnect stops Wizardry control without unpairing devices or deleting saved computer credentials.

See [release and account setup](docs/SETUP.md) and [the first-wave device checklist](docs/WAVE_ONE.md).

## Activate · Extend · Adjust · Lock

**Touch-free entry:** configure [AssistiveTouch launch](docs/SETUP.md#assistivetouch-launch), then **raise wrist → double finger touch → hold still → ready haptic → wrist action**. The shortcut opens Wizardry's control screen, starts a 30-minute session, and arms after 250 ms of steady motion. The configured armed window starts when calibration completes; the launch gesture cannot also execute an action. Return to neutral between actions. Repeat the shortcut whenever you need to open and arm Wizardry again.

**Manual entry:** tap **Arm**, hold still while looking at the watch, and wait for the ready haptic. There is no separate twist-to-wake sequence.

**Live volume knob (experimental):** connect **Computer** or **Phone**, activate, then extend until the wrapped z / yaw change reaches **55° in either direction** from the ready pose. Entry uses the first fresh sample across the threshold, without waiting for the arm to settle. Twist your wrist like a knob: **positive twist increases volume; negative twist decreases it**. The starting level comes from the selected output; 90° of twist changes it by 50 percentage points, with a full 180° range spanning 0–100%. Use small turns. Wrapped roll prevents a jump when the angle crosses ±180°, and reversing at a volume limit responds immediately. Raising/lowering is no longer the volume input.

The Watch can start up to 50 updates per second with at most four outstanding updates; actual applied rate depends on paired transport and output readback. Crossing the viewing yaw and holding still do not end adjustment. A personalized single finger touch or **Lock volume** stops it. Keep AssistiveTouch single touch at **None**. Requested and acknowledged percentages remain separate. Update both apps and restart the updated receiver for Computer. See [setup, protocol, and pending hardware validation](docs/LIVE_VOLUME.md).

| Motion | Computer default | Phone default | Home default |
|---|---|---|---|
| Twist + | Volume up | Volume Up Shortcut | Selected light/plug on |
| Twist − | Volume down | Volume Down Shortcut | Selected light/plug off |
| Tilt up | Next track | Spotify next track | Selected Home scene |
| Tilt down | Previous track | Spotify previous track | iPhone locator chime |
| Double shake | Play/pause | Spotify play/pause | Toggle selected light/plug |

Home targets start unassigned: choose them before testing. Gesture directions depend on wrist/orientation; use Live to inspect them. These are tunable motion heuristics, not a trained gesture model.

## Runtime and platform limits

**Temporary autorotation (experimental):** Wizardry enables `WKApplication.shared().isAutorotating` when foreground hold-still calibration starts. The same lease continues through the ready haptic, the armed countdown, live volume, and its final acknowledgement, capped at ten minutes from calibration and the outer session's remaining duration. Disarm/expiry, failure, settings changes, explicit stopping, enrollment, Now Playing, or backgrounding releases it. Idle screens and enrollment never enable it; raising the wrist never restarts it. The interface may flip when you rotate your wrist away. Inactive calibration and recognition continue only with the existing lease and fresh motion samples. Samples more than 250 ms old, future timestamps, duplicates, and out-of-order samples are rejected. Delivery gaps clear incomplete gestures and require returning to neutral before another discrete action; volume stops on interrupted sensing. Expired interactions require fresh activation, without automatic retries.

Apple documents autorotation as keeping the interface awake during wrist flips used to show it to another viewer, and recommends enabling it selectively. This build uses that behavior for bounded gesture interactions; it does not start `WKExtendedRuntimeSession` or declare a background runtime mode. The ten-minute cap is Wizardry's limit, not an OS autorotation limit. Gesture calculations retain their calibrated sensor angles independently of interface rotation. **Release acceptance requires the physical display to remain awake during movement, backward tilt, and stationary pauses in live volume; dimming while control continues does not pass.** The user reported rotation working in build **0.2.0 (15.1)**. Build **16.1** added stationary-hold behavior; its physical hold, full pose, and battery checks remain pending. Autorotation is not a guarantee for every pose or indefinite use. See [Apple's autorotation documentation](https://developer.apple.com/documentation/watchkit/wkapplication/isautorotating) and [physical checks](docs/WAVE_ONE.md).

Stationary live volume keeps its autorotation lease and sends an unchanged-volume heartbeat each second. The phone and receiver still stop sessions that receive no request for six seconds. That delivery watchdog remains separate from holding still; motion-sample gaps, transport failures, manual lock, explicit interruptions, and the ten-minute cap still end the interaction.

During an active 30-minute session, returning after disarming requires shortcut/button activation again. The AssistiveTouch shortcut or Siri's “Start Wizardry” opens and arms a fresh session after hold-still calibration. A shortcut activation expires after ten seconds if launch/calibration cannot complete. An inactive transition preserves calibration only while its existing lease remains valid and fresh samples continue; backgrounding cancels it. An ordinary wrist raise cannot replay a canceled activation. Return to Clock and Wrist Flick settings may affect observed behavior, but changing them does not establish that the display-awake requirement passes.

**Awake diagnostics** on Watch and iPhone show scene/application state, requested and read-back autorotation, reduced luminance, delivered raw/device-motion Hz, sample age, processing delay, confirmed acknowledgement Hz, round-trip time, and the last typed stop reason. The Watch persists a bounded history of 48 events. Acknowledgement Hz measures replies, not actual applied-output Hz; stationary display, full pose coverage, output timing, and battery checks remain pending.

AssistiveTouch requires one-time user setup and replaces Apple's standard Double Tap. With AssistiveTouch off, standard Double Tap activates Arm while Wizardry is visible on supported watches. No fake workouts or continuous silent audio are used. Shortcut discovery, gesture launch, and end-to-end action delivery remain subject to the [physical-device checks](docs/WAVE_ONE.md).

**Spotify:** Premium and developer authorization are required. Controls target the current active Spotify player; start playback there first. Remote volume only works when that player advertises support. Spotify iPhone volume may be unavailable through its API.

**Live iPhone volume (experimental):** connect **Phone** and keep Wizardry open on iPhone with its native volume slider visible on Control, Live, or Setup. Use the same 55° yaw entry, signed twist-knob adjustment, and single-touch/button lock flow as Computer. The native-slider bridge now hosts a plain `MPVolumeView` instead of subclassing it; that fix does not establish physical-device success. It requires actual `AVAudioSession.outputVolume` readback before confirming an applied level. No Shortcut, receiver pairing, or Spotify authorization is needed for live volume. Leaving the phone app, hiding the slider, changing output, expiry, or failed readback stops adjustment without retrying. This controls media volume, not ringer volume, and cannot operate with the iPhone locked. Apple does not document a programmatic system-volume setter; physical validation remains required. See [iPhone checks](docs/LIVE_VOLUME.md#live-iphone-volume-experimental).

**Discrete iPhone volume:** existing twist mappings still use `Wizardry Volume Up` / `Wizardry Volume Down` Shortcuts with Get Device Details → Current Volume, Calculate ±0.06, then Set Volume. Shortcut handoffs cannot report completion. Native volume and Watch Now Playing's Digital Crown remain available.

**Home:** access must be granted on the phone; accessory reachability depends on the Home network and hub. Only light/outlet/switch power characteristics are enumerated. Home scenes are explicitly selected by the user.

A recognition haptic confirms a gesture, not successful execution. The watch and phone display target acknowledgements, dry runs, handoffs, and errors separately. Discrete commands expire after five seconds; live volume messages expire after one second. Live volume retains only the newest waiting target while one phone write executes; it never queues commands for later recovery or automatically retries them.

## Privacy and pairing

Normal motion processing happens on the Watch. iPhone Control/Live request bounded telemetry and retain at most 240 graph samples in memory. **Computer studio** is a separate explicit opt-in: the foreground iPhone relays Watch sensors to the paired local receiver, where named recordings can be saved under `receiver/data/`. Keep Wizardry visible on the Watch and iPhone. No sensor recordings are sent to a cloud service or Spotify. Receiver tokens and Spotify refresh tokens stay in the iPhone Keychain; the Watch and browser dashboard do not receive pairing credentials.

Computer HTTP is intended for a trusted private LAN. HTTPS with a trusted certificate is supported. Receiver commands use an explicit allowlist, token authentication, replay checks, expiry, and rate limiting. Presentation keys affect the currently focused computer application.

## Computer studio

Double-click **Start-Wizardry.cmd** to open the receiver dashboard and studio in dry-run mode, or run `Start-Wizardry.cmd --execute` for computer commands. Enable **Computer studio** on the foreground iPhone and choose **Live sensors → Start sensors** on the computer. Monitoring is independent of the command target: Phone can remain selected while its Watch motion is viewed on the computer. There is still only one command target.

In **Record movements**, create a named movement and choose **Record example**. Stay still during **Preparing**; move only after the Watch confirms recording and the dashboard shows **Recording — move now**. Capture disables Watch gesture actions. **Stop & save** writes the recording locally; **Cancel** discards it. Recordings stop after 60 seconds, and interrupted or incomplete takes carry quality information instead of becoming validated examples.

**Map movements** saves custom movement/action labels for later training; recording and mapping alone do not enable recognition. Existing Computer/Phone discrete mappings can also be edited there, and must receive the iPhone's current-configuration acknowledgement before they are shown as applied. Edit Home targets on iPhone. See the [receiver guide](receiver/README.md) for studio setup and files.

## Development and validation

- `python -m unittest discover -s receiver -v`
- `python -m unittest discover -s scripts/tests -v`
- `swift test` on a system with Swift, or GitHub Actions.
- `project.yml` is the XcodeGen source. `Wizardry` builds the Watch; `WizardryPhone` builds/tests the companion; `WizardryDistribution` archives both.
- CI tests explicit activation, relative-yaw extension, command gating, receiver HTTP, both native targets, archive metadata, and iPhone UI navigation with screenshot artifacts.
- Signed distribution remains manual, main-only, and gated by successful CI on the exact commit.

Simulator and CI success cannot verify real gestures, paired-device background delivery, Home accessories, Spotify authorization, battery use, or installation. Record those on hardware in the device checklist.
