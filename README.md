# Wizardry: Magic at a Wave

A native iPhone and Apple Watch gesture remote, developed on Windows and built with Xcode in GitHub Actions.

## Wave one · 0.2

- **iPhone companion:** set up your computer, connect Apple Home and Spotify, select a profile, and edit every gesture-to-action mapping.
- **Watch:** touch-free AssistiveTouch/Shortcut launch with hold-still calibration and automatic arming, a 30-minute control session, explicit shortcut/button arming, experimental live computer/iPhone volume and learned single-touch locking, an eight-second armed window, Double Tap on supported watches, and native Now Playing controls.
- **Live motion:** opening screens show twist, tilt, yaw and volume feedback. iPhone Control / Live include a requested-versus-acknowledged volume graph and all sensor axes. Requested 100 Hz capture (actual hardware rate displayed), up to 20 Hz display, roughly 100 ms telemetry batches, bounded local buffers, and explicit stale status.
- **Computer:** Windows volume, mute, play/pause, track navigation, and next/previous slide or page. Launching the receiver opens a local visual display with a live volume dial, confirmed-volume chart, gesture guidance, and recent actions (`--no-ui` for console-only use).
- **Phone:** Spotify playback on the active player, Apple Music controls, a locator chime, native volume slider, and named Shortcuts.
- **Apple Home:** select existing lights, switches, Matter plugs, or scenes. No separate Matter commissioning is required.

## Install and set up

Install the latest Wizardry beta using TestFlight on the iPhone paired with your Watch. Version 0.2 adds a real iPhone app to the existing watch app. Open Wizardry on both devices; Apple's existing pairing links them automatically.

In **Setup** on iPhone:

1. Sync settings to the watch.
2. Pair the optional [computer receiver](receiver/README.md) using its LAN address and token.
3. Connect Apple Home, then choose your devices and scenes in **Motions**.
4. Connect Spotify Premium. A Spotify developer client must be configured; the app uses PKCE without a client secret. Start Spotify on your intended playback device first.
5. Select **Computer**, **Phone**, or **Home** on Control. Editing a profile does not activate it.

See [release and account setup](docs/SETUP.md) and [the first-wave device checklist](docs/WAVE_ONE.md).

## Activate · Extend · Adjust · Lock

**Touch-free entry:** configure [AssistiveTouch launch](docs/SETUP.md#assistivetouch-launch), then **raise wrist → double finger touch → hold still → ready haptic → wrist action**. The shortcut opens Wizardry's control screen, starts a 30-minute session, and arms after 250 ms of steady motion. The configured armed window starts when calibration completes; the launch gesture cannot also execute an action. Return to neutral between actions. Repeat the shortcut whenever you need to open and arm Wizardry again.

**Manual entry:** tap **Arm**, hold still while looking at the watch, and wait for the ready haptic. There is no separate twist-to-wake sequence.

**Live computer volume (experimental):** with the Computer profile selected, extend your arm until z / yaw changes about 90 degrees from the pose at the ready haptic. After the entry haptic, raise/lower your hand in short strokes with pauses. The direction is flipped from the previous build to match the user's observed setup: raise increases volume, lower decreases it. Volume changes incrementally from the actual Windows volume, with up to 20 acknowledged updates per second (paired/network latency lowers the delivered rate). A personalized single finger touch or the **Lock volume** button stops adjustment; five seconds without movement also ends it. Keep AssistiveTouch single touch at **None**. Requested and acknowledged volume are shown separately. Update both apps and restart the updated receiver together. See [enrollment, protocol, and pending hardware validation](docs/LIVE_VOLUME.md).

| Motion | Computer default | Phone default | Home default |
|---|---|---|---|
| Twist + | Volume up | Volume Up Shortcut | Selected light/plug on |
| Twist − | Volume down | Volume Down Shortcut | Selected light/plug off |
| Tilt up | Next track | Spotify next track | Selected Home scene |
| Tilt down | Previous track | Spotify previous track | iPhone locator chime |
| Double shake | Play/pause | Spotify play/pause | Toggle selected light/plug |

Home targets start unassigned: choose them before testing. Gesture directions depend on wrist/orientation; use Live to inspect them. These are tunable motion heuristics, not a trained gesture model.

## Runtime and platform limits

**Temporary autorotation (experimental):** after hold-still calibration and before the ready haptic, Wizardry enables `WKApplication.shared().isAutorotating` for the existing armed countdown. It disables autorotation on disarm/expiry, settings changes, stopping, enrollment, Now Playing, or leaving Wizardry. Live volume retains autorotation until adjustment locks/stops or fails, capped at ten minutes from readiness and the outer session's remaining duration. Idle screens, calibration, and enrollment never enable it; raising the wrist never restarts it. The interface may flip when you rotate your wrist away. During inactive foreground periods, recognition continues only while fresh motion samples arrive. Samples more than 250 ms old, future timestamps, duplicates, and out-of-order samples are rejected. Delivery gaps clear incomplete gestures and require returning to neutral before another action; they never extend the armed window. An expired interaction requires fresh activation, without automatic retries.

Apple documents autorotation as keeping the interface awake during wrist flips used to show it to another viewer, and recommends enabling it selectively. This build uses that behavior for bounded gesture interactions; it does not start `WKExtendedRuntimeSession` or declare a background runtime mode. The ten-minute cap is Wizardry's limit, not an OS autorotation limit. Gesture calculations retain their calibrated sensor angles independently of interface rotation. Sideways/palm-up behavior, motion delivery, latency, and battery impact still need physical-watch validation. See [Apple's autorotation documentation](https://developer.apple.com/documentation/watchkit/wkapplication/isautorotating).

During an active 30-minute session, returning after disarming requires shortcut/button activation again. The AssistiveTouch shortcut or Siri's “Start Wizardry” opens and arms a fresh session after hold-still calibration. A shortcut activation expires after ten seconds if launch/calibration cannot complete. Becoming inactive during calibration still cancels activation; an ordinary wrist raise cannot replay it. Set Watch **Settings → General → Return to Clock → After 1 hour** for a reading session. If rolling returns you to the watch face, try **Settings → Gestures → Wrist Flick → Off**. Inactive motion delivery must be tested on hardware; suspension can still interrupt a gesture.

AssistiveTouch requires one-time user setup and replaces Apple's standard Double Tap. With AssistiveTouch off, standard Double Tap activates Arm while Wizardry is visible on supported watches. No fake workouts or continuous silent audio are used. Shortcut discovery, gesture launch, and end-to-end action delivery remain subject to the [physical-device checks](docs/WAVE_ONE.md).

**Spotify:** Premium and developer authorization are required. Controls target the current active Spotify player; start playback there first. Remote volume only works when that player advertises support. Spotify iPhone volume may be unavailable through its API.

**Live iPhone volume (experimental):** select **Phone** on Control and keep Wizardry open on iPhone with its native volume slider visible on Control, Live, or Setup. Use the same Watch activation, relative-yaw extension, vertical raise/lower, and single-touch/button lock flow as Computer. A native-slider bridge writes media volume during movement and acknowledges actual `AVAudioSession.outputVolume` readback. No Shortcut, receiver pairing, or Spotify authorization is needed for live volume. Leaving the phone app, hiding the slider, changing the audio output, expiry, or failed readback stops adjustment without retrying. This does not control ringer volume or operate with the iPhone locked. Apple does not document a programmatic system-volume setter; the bridge depends on the native control's implementation and needs physical-device validation. See [iPhone setup and checks](docs/LIVE_VOLUME.md#live-iphone-volume-experimental).

**Discrete iPhone volume:** existing twist mappings still use `Wizardry Volume Up` / `Wizardry Volume Down` Shortcuts with Get Device Details → Current Volume, Calculate ±0.06, then Set Volume. Shortcut handoffs cannot report completion. Native volume and Watch Now Playing's Digital Crown remain available.

**Home:** access must be granted on the phone; accessory reachability depends on the Home network and hub. Only light/outlet/switch power characteristics are enumerated. Home scenes are explicitly selected by the user.

A recognition haptic confirms a gesture, not successful execution. The watch and phone display target acknowledgements, dry runs, handoffs, and errors separately. Discrete commands expire after five seconds; live volume messages expire after one second. Both are never queued for later execution or automatically retried.

## Privacy and pairing

Motion processing happens on the Watch; live samples are sent only to the paired iPhone while its Control or Live screen requests them. Graphs retain at most 240 samples in memory. No motion samples are uploaded to Spotify or a server. Spotify requests contain only the authorization and player-control information its service requires. Receiver tokens and Spotify refresh tokens stay in the iPhone Keychain. The watch receives gesture mappings, not credentials.

Computer HTTP is intended for a trusted private LAN. HTTPS with a trusted certificate is supported. Receiver commands use an explicit allowlist, token authentication, replay checks, expiry, and rate limiting. Presentation keys affect the currently focused computer application.

## Development and validation

- `python -m unittest discover -s receiver -v`
- `python -m unittest discover -s scripts/tests -v`
- `swift test` on a system with Swift, or GitHub Actions.
- `project.yml` is the XcodeGen source. `Wizardry` builds the Watch; `WizardryPhone` builds/tests the companion; `WizardryDistribution` archives both.
- CI tests explicit activation, relative-yaw extension, command gating, receiver HTTP, both native targets, archive metadata, and iPhone UI navigation with screenshot artifacts.
- Signed distribution remains manual, main-only, and gated by successful CI on the exact commit.

Simulator and CI success cannot verify real gestures, paired-device background delivery, Home accessories, Spotify authorization, battery use, or installation. Record those on hardware in the device checklist.
