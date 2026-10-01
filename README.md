# Wizardry: Magic at a Wave

A native iPhone and Apple Watch gesture remote, developed on Windows and built with Xcode in GitHub Actions.

## Wave one · 0.2

- **iPhone companion:** set up your computer, connect Apple Home and Spotify, select a profile, and edit every gesture-to-action mapping.
- **Watch:** a 30-minute control session, deliberate double-twist wake, an eight-second armed window, Double Tap on supported watches, Siri session launch, and native Now Playing controls.
- **Live motion:** graphs and numeric values for acceleration, rotation rate, relative roll/pitch, yaw, and gravity. About 50 Hz capture, 10 Hz display, bounded local buffers, and explicit stale status.
- **Computer:** Windows volume, mute, play/pause, track navigation, and next/previous slide or page.
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

## Raise · Wake · Act

Start a session on the Watch. Hold still for calibration. With Wizardry frontmost, twist **+ / − / + / −** (or the reverse) within **2.5 seconds**. A double haptic arms the watch. Return to neutral briefly, then make the action gesture within the armed window. Return to neutral between actions.

| Motion | Computer default | Phone default | Home default |
|---|---|---|---|
| Twist + | Volume up | Volume Up Shortcut | Selected light/plug on |
| Twist − | Volume down | Volume Down Shortcut | Selected light/plug off |
| Tilt up | Next track | Spotify next track | Selected Home scene |
| Tilt down | Previous track | Spotify previous track | iPhone locator chime |
| Double shake | Play/pause | Spotify play/pause | Toggle selected light/plug |

Home targets start unassigned: choose them before testing. Gesture directions depend on wrist/orientation; use Live to inspect them. These are tunable motion heuristics, not a trained gesture model.

## Runtime and platform limits

**This is not always-on background recognition.** watchOS suspends ordinary apps. Sensors pause and actions disarm on wrist-down/inactive/background transitions. During an active 30-minute session, returning to Wizardry resumes calibration; wake/arm is required again unless explicitly disabled. Set Watch **Settings → General → Return to Clock → After 1 hour** for a reading session. If the clock or another app is showing, reopen Wizardry; Siri's “Start Wizardry” app shortcut can open a session. Double Tap activates Arm while Wizardry is visible on supported watches. No fake workouts or continuous silent audio are used.

**Spotify:** Premium and developer authorization are required. Controls target the current active Spotify player; start playback there first. Remote volume only works when that player advertises support. Spotify iPhone volume may be unavailable through its API.

**iPhone volume:** use the native slider or Watch Now Playing's Digital Crown. Gesture volume uses user-created Shortcuts while Wizardry is foreground on iPhone. Create `Wizardry Volume Up` / `Wizardry Volume Down` using Get Device Details → Current Volume, Calculate ±0.06, then Set Volume. Launching a Shortcut opens Shortcuts and cannot report completion. These are not silent locked-phone volume controls.

**Home:** access must be granted on the phone; accessory reachability depends on the Home network and hub. Only light/outlet/switch power characteristics are enumerated. Home scenes are explicitly selected by the user.

A recognition haptic confirms a gesture, not successful execution. The watch and phone display target acknowledgements, dry runs, handoffs, and errors separately. Commands expire after five seconds and are never queued for later execution or automatically retried.

## Privacy and pairing

Motion processing happens on the Watch; live samples are sent only to the paired iPhone while its Live screen requests them. Graphs retain at most 240 samples in memory. No motion samples are uploaded to Spotify or a server. Spotify requests contain only the authorization and player-control information its service requires. Receiver tokens and Spotify refresh tokens stay in the iPhone Keychain. The watch receives gesture mappings, not credentials.

Computer HTTP is intended for a trusted private LAN. HTTPS with a trusted certificate is supported. Receiver commands use an explicit allowlist, token authentication, replay checks, expiry, and rate limiting. Presentation keys affect the currently focused computer application.

## Development and validation

- `python -m unittest discover -s receiver -v`
- `python -m unittest discover -s scripts/tests -v`
- `swift test` on a system with Swift, or GitHub Actions.
- `project.yml` is the XcodeGen source. `Wizardry` builds the Watch; `WizardryPhone` builds/tests the companion; `WizardryDistribution` archives both.
- CI tests gesture/wake state, command gating, receiver HTTP, both native targets, archive metadata, and iPhone UI navigation with screenshot artifacts.
- Signed distribution remains manual, main-only, and gated by successful CI on the exact commit.

Simulator and CI success cannot verify real gestures, paired-device background delivery, Home accessories, Spotify authorization, battery use, or installation. Record those on hardware in the device checklist.
