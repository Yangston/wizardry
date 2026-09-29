# Wizardry

An Apple Watch wrist-motion controller, developed from Windows with cloud macOS builds.

**First milestone:** open Wizardry on your watch, tap Start, rotate your wrist, and get one haptic confirmation. The app displays live motion, relative roll, actual sample frequency, the last gesture, and a gesture counter. A separate vibration button works without motion sensing.

## Get it onto your watch

Follow **[the Windows-to-TestFlight setup guide](docs/SETUP.md)**. The unsigned **Build and test** workflow requires no Apple credentials. The manual **Upload to TestFlight** workflow requires your paid Apple Developer account and signing configuration.

The project targets **watchOS 10+**. A non-launchable iOS 17+ distribution container packages the watch-only app for TestFlight; this is not an iPhone companion app. An iPhone paired to the watch is used to install the TestFlight build. Check your watch and phone versions before enrolling.

## What is included

- SwiftUI watch app with Core Motion sampling requested at 50 Hz; UI refreshes at 10 Hz.
- Relative-roll detector with sustained threshold, cooldown, and neutral-pose rearming.
- Haptic feedback, live diagnostics, and explicit Start/Stop.
- Optional LAN commands with acknowledgement and no delayed retries.
- Python receiver with dry-run mode; optional Windows volume control.
- XcodeGen project, simulator build, unsigned distribution archive validation, and a manual signing/upload workflow.
- Gesture-state-machine tests and receiver tests, including an actual HTTP round trip.

## Try it

1. Open Wizardry and hold your wrist comfortably still.
2. Tap **Start**. The first sensor sample establishes the starting pose.
3. Rotate until the displayed roll exceeds about **37°** in either direction for at least **0.12 seconds**.
4. Expect a haptic click and one counter increment.
5. Return within about **9°** of the initial pose for **0.25 seconds**, after the **1-second** cooldown, before repeating.
6. Tap Stop/Start to recalibrate at a different pose.

The +/− directions are sensor-relative; left/right wrist and watch orientation affect which movement increases roll. They are intentionally not labelled clockwise/counterclockwise. This is a threshold prototype, not a trained gesture model.

## Runtime limits

Capture stops when the app is no longer active, including wrist-down/inactive transitions. It never silently restarts. This version does not provide all-day or background gesture listening and does not misuse workout sessions to stay alive. A haptic confirms **local detection**; the Computer screen separately reports whether a network command succeeded.

## Optional computer control

See **[receiver instructions](receiver/README.md)**. First test a ping in dry-run mode. Then enable Windows volume execution and the watch's “Gestures control volume” toggle. Pi/Linux can run the dry-run receiver; actual device/light integrations are future work.

Plain HTTP is enabled for this LAN prototype through an App Transport Security exception. Pairing tokens are session-only on the watch. Use a trusted private network, or configure HTTPS with a certificate trusted by the watch. There is no cloud dependency for gesture processing or device commands; GitHub and Apple are used for building and installation.

## Repository map

| Path | Purpose |
|---|---|
| `WatchApp/` | Watch interface, sensors, and command client |
| `Sources/GestureCore/` | Platform-independent rotation detector |
| `Tests/GestureCoreTests/` | Detector regression tests |
| `project.yml` | Source of truth for the generated Xcode project |
| `.github/workflows/build.yml` | Unsigned builds, archive validation, tests |
| `.github/workflows/testflight.yml` | Manual signed upload |
| `receiver/` | Local computer receiver and tests |
| `docs/SETUP.md` | Account setup and installation |

## Development

On Windows: edit with VS Code/Codex, run `python -m unittest discover -s receiver -v`, commit, and push. If Swift is installed locally, run `swift test` for the detector. Apple framework compilation happens in Actions.

On a Mac: install Xcode and XcodeGen, run `xcodegen generate`, then open `Wizardry.xcodeproj`. The `Wizardry` scheme runs the watch app; `WizardryDistribution` archives its container. Generated projects and signing assets are excluded from Git.

## Verification checklist on hardware

- [ ] Test vibration works.
- [ ] Start shows changing acceleration/rotation and a plausible actual sampling rate.
- [ ] Each deliberate rotation fires once; a held pose does not repeat.
- [ ] Returning to neutral rearms; small movements and brief spikes do not trigger.
- [ ] Stop, wrist-down, and app switching stop capture.
- [ ] Test command reaches the receiver; dry-run status is distinguished from executed status.
- [ ] Enable execution and verify the direction of one volume step.
- [ ] Turn off the receiver and confirm an error, with no queued command firing later.

Cloud build success cannot establish physical gesture accuracy, haptic behavior, battery use, or LAN routing; those require your watch.
