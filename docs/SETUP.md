# Build and release Wizardry

## Existing account setup

- App Store Connect: **Wizardry: Magic at a Wave**, Apple ID `6817949081`.
- iPhone bundle: `com.yangston.wizardry`.
- Watch bundle: `com.yangston.wizardry.watchkitapp`.
- Apple team: `KLMGNNCJGV`.
- GitHub: `Yangston/wizardry`, protected `testflight` environment, branch `main` only.
- Internal group: **Personal Testing**, containing the owner, with automatic build distribution.

Version 0.1 was watch-only. Version 0.2 makes the existing root bundle a real iPhone application and embeds its paired watch companion. Do not restore `ITSWatchOnlyContainer`, `LSApplicationLaunchProhibited`, or `WKWatchOnly`. The Watch Info.plist must identify the iPhone root through `WKCompanionAppBundleIdentifier`.

The phone's Apple identifier has HomeKit enabled. Its generated entitlements include `com.apple.developer.homekit`. Home access is still granted by the user on the physical iPhone; enabling signing capability does not grant access to anyone's home.

## Upgrading an existing Watch-only installation

Apple's metadata for 0.2.0 (3.2) confirms **Watch-Only App: No** and **Device Family: iPhone, iPad, Apple Watch**. Both apps use one TestFlight listing.

An existing 0.1 Watch-only installation can block the iPhone installation with: "A watchOS version of this app is already installed on your Apple Watch. To install this app on your iOS device, delete the watchOS version."

If TestFlight shows that specific message:

1. Delete **Wizardry** from the Apple Watch. This resets Wizardry's local Watch settings.
2. Install the latest **0.2.0** build in TestFlight on the paired iPhone.
3. Open Wizardry on the iPhone.
4. In TestFlight, open Wizardry's **App Details → Apple Watch** and install its Watch companion.
5. Open both apps and use iPhone **Setup → Sync settings to watch**.

This is a one-time installation-order migration; subsequent paired-app builds update normally. If the expected build is not selected, use TestFlight's Previous Builds picker. Do not infer an archive defect from the old Watch installation alone; inspect the build metadata and the exact device error.

## Connect a control target

Connect **Computer** or **Phone** from the Watch, or select the intended target and use **Connect Watch** on iPhone. Watch commands always pass through the paired iPhone, including Computer commands. Only one command target is active. Computer requires the saved receiver address/token; live Phone volume requires the foreground iPhone app and visible native slider. Select Home on iPhone when using configured Home actions.

**Disconnect** stops Wizardry command control and invalidates the active interaction. It does not unpair Apple Watch/Bluetooth, delete receiver credentials, or revoke Spotify authorization. Reconnect the intended target, then activate afresh. Connection status reports Wizardry's control state and target acknowledgement, not a promise that every future output action will succeed. Merely editing another profile does not activate it.

## AssistiveTouch launch

The intended flow is **raise wrist → double finger touch → hold still → ready haptic → wrist action**, with no screen tap after setup. Install the updated app on **both iPhone and Apple Watch** first and open each once for setup and permissions.

1. On iPhone, open **Shortcuts**, create a shortcut named **Activate Wizardry**, and add Wizardry's **Start Wizardry session** action. Use that action, not the generic Open App action, so the watch also calibrates and arms.
2. In the shortcut's details, enable **Show on Apple Watch**. Let it sync and check that Activate Wizardry appears in Shortcuts on the watch. Run it there once and complete any system permission prompts.
3. On the watch, enable **Settings → Accessibility → AssistiveTouch → Hand Gestures**.
4. Select **double finger touch**, choose the Siri Shortcut **Activate Wizardry**, and set **Activation Gesture → None** if that option is available on the installed watchOS version. Otherwise, perform the configured AssistiveTouch activation gesture first, then double finger touch to run the shortcut. Menu wording may vary by watchOS version.
5. From the watch face, raise your wrist, perform the configured gesture, and hold still until Wizardry gives its ready haptic. Then make your twist, tilt, or shake action. The separate twist-to-wake sequence has been removed. Return to neutral between actions.

The action is exposed in both apps so it can be configured on iPhone, but **execute it on Apple Watch**. Running it on iPhone displays an instruction to use the watch; it does not remotely launch the watch app. If the action is missing, confirm both updated apps are installed and have been opened, then recheck Shortcuts discovery. Do not substitute a phone-only Open App shortcut.

Assign AssistiveTouch **single finger touch to None**. Wizardry's optional personalized single-touch recognizer owns that input; before enrollment, **Lock volume** remains available onscreen.

Wizardry waits for 250 ms of low acceleration and rotation before calibrating the current wrist position and starting the configured armed window. Repeating the shortcut starts a fresh 30-minute session and restarts calibration. Launch motion cannot trigger a mapped action. A ready haptic means gesture input is ready, not that the iPhone, music player, computer, or Home target has acknowledged an action.

If launch or calibration takes ten seconds, Wizardry cancels the activation and asks you to activate again. An inactive transition during calibration preserves the request only with its existing autorotation lease and fresh motion samples; backgrounding, stopping the session, changing settings, or losing the motion sensor cancels it. Raising your wrist later does not replay a canceled request. When Wizardry is already frontmost, its Arm button remains available.

AssistiveTouch replaces Apple's standard Double Tap and must be configured by the user; Wizardry cannot change those system settings. It launches **foreground** gesture detection, not an always-on background listener. See [Apple's AssistiveTouch guide](https://support.apple.com/en-mide/guide/watch/apdec70bfd2d/watchos) and [activation instructions](https://support.apple.com/en-us/111111).

After the ready haptic, brief dimming preserves the **remaining** armed time and calibrated wrist position. It never restarts the countdown. Gestures can continue if watchOS keeps delivering fresh motion samples. If delivery is interrupted, incomplete gestures are discarded and you must return to neutral before acting again. Late samples are never replayed as commands. Actually leaving Wizardry, navigating to Now Playing, stopping, changing settings, or sensor failure still disarms the watch. Without an explicit armed window, detection pauses while inactive regardless of legacy saved wake settings.

This experimental build enables temporary autorotation as foreground calibration starts and retains the same lease through readiness, the armed countdown, live volume, and its final acknowledgement. Apple documents this as keeping the interface awake when the wrist flips to show it to another viewer; the interface may flip during your gesture. The app limit is ten minutes from calibration, bounded by the outer session. Idle screens and enrollment do not enable it. Expiry, disarm, failure, Now Playing, settings changes, explicit stopping, or backgrounding releases it; a wrist raise cannot re-enable an expired interaction. No extended runtime session or self-care capability is used. See [Apple's autorotation documentation](https://developer.apple.com/documentation/watchkit/wkapplication/isautorotating).

The release requirement is for the **display itself to remain awake during movement, backward tilt, and stationary pauses in live volume**. Dimming with continuing volume control is not a substitute. The user reported rotation working in **0.2.0 (15.1)**. Build **16.1** added stationary-hold behavior, but physical holds, full pose coverage, and battery checks remain pending. The autorotation request does not establish a guarantee for every orientation or indefinite use. Use **Awake diagnostics** on Watch/iPhone to correlate requested/read-back autorotation, reduced luminance, lifecycle state, sample timing, acknowledgement cadence, and stop reasons with what the display actually does. The Watch retains a bounded 48-event diagnostic history.

Holding still during live volume retains the same session and autorotation lease; twisting resumes adjustment without reactivation. There is no five-second stationary auto-exit. An unchanged-volume heartbeat runs once a second. The six-second phone/receiver missing-request watchdogs, stale sensing/transport failures, manual lock, explicit disconnect/stop, and the ten-minute cap remain enforced. Physically test a 10–30-second hold for an awake display and constant volume before accepting this stationary behavior.

For the volume knob, extend to **55° absolute wrapped yaw** from the ready pose. Either direction enters on the first fresh sample without additional settling or an upper-angle cutoff. The current output volume and roll anchor adjustment: positive twist increases, negative twist decreases, and a 90° turn changes volume by 50 percentage points. Use small turns; wrapped deltas handle ±180° crossings. Raising/lowering is no longer the volume input, and crossing the viewing yaw does not exit adjustment.

Install both updated apps and restart the updated Computer receiver. Transport v2 permits up to 50 update starts/s and four outstanding Watch updates; the phone executes one write and keeps only the newest waiting target. Receiver capability is checked before adjustment. Actual applied-output cadence requires the measurements in [LIVE_VOLUME.md](LIVE_VOLUME.md); confirmed acknowledgement Hz is not applied-output Hz.

On supported watches, **Settings → Gestures → Wrist Flick → Off** may prevent rolls from being interpreted as the system's dismissal gesture. See [Apple's Wrist Flick guide](https://support.apple.com/guide/watch/use-gestures-for-notifications-and-alerts-apd8bcbaa778/27/watchos/27).

The shortest gesture sequence, synced Shortcut routing, launch latency, motion continuity during dimming, and locked-phone action delivery must be verified on a real paired watch and phone. Record results in [the device checklist](WAVE_ONE.md); simulator builds do not validate this flow.

## Routine beta release

1. Commit and push the intended changes to `main`.
2. Wait for **Build and test** on that exact commit. It runs portable Swift tests, Watch compilation, an unsigned paired iPhone/Watch archive check, Windows receiver tests, release-gate tests, and native iPhone UI tests with screenshot artifacts.
3. Inspect `phone-screenshots` for affected UI. Simulator screenshots are UI evidence, not live paired Watch/Home/Spotify validation.
4. Manually run **Upload to TestFlight** on `main`. The workflow enforces exact-commit CI before accessing signing secrets.
5. Verify the signed archive, export, and upload, then verify **Apple processing** in TestFlight. Upload success alone is not processing success.
6. Verify the Personal Testing group has the processed build and the tester. Save concise What to Test notes. Install on the paired iPhone and Watch, then perform [hardware checks](WAVE_ONE.md).

The workflow does not submit a public App Store release or invite external testers. It does not require owning a Mac; Xcode runs on GitHub's macOS runner. Xcode 26.3 is selected on `macos-15`; update the runner/toolchain together if retired.

`project.yml` is the source of truth. Generated Xcode projects, private keys, profiles, and archives stay out of Git. `WizardryDistribution` archives the iPhone app and embedded Watch. `WizardryPhone` includes the iPhone UI test target.

## Signing configuration

Existing signing keys were reused from You Can't Park There with the owner's approval. Do not recreate working keys for routine updates. Private backups remain outside the repository.

| Environment entry | Kind |
|---|---|
| `APP_STORE_CONNECT_ISSUER_ID` | Secret |
| `APP_STORE_CONNECT_KEY_IDENTIFIER` | Secret |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Secret; complete team `.p8` text |
| `CERTIFICATE_PRIVATE_KEY` | Secret; persistent distribution `.pem` text |
| `APPLE_TEAM_ID` | Variable |
| `APP_STORE_APP_ID` | Variable; `6817949081` |
| `BUNDLE_ID` | Variable; `com.yangston.wizardry` |
| `SPOTIFY_CLIENT_ID` | Variable; public Spotify developer client identifier, prefilled into signed builds |

The team API key must manage certificates/profiles as well as upload. App Manager works for the established setup. The API key and distribution private key have different purposes. Never print them, commit them, paste them into chat, or regenerate the certificate key on every build. GitHub cannot reveal saved secret values.

The signing workflow fetches profiles for both bundles. After enabling a capability such as HomeKit, ensure the selected profile contains the entitlement; a stale profile must be regenerated, not worked around by stripping the entitlement.

Both Info.plists explicitly bind `CFBundleVersion` to `$(CURRENT_PROJECT_VERSION)` and `CFBundleShortVersionString` to `$(MARKETING_VERSION)`. Build numbers are `GITHUB_RUN_NUMBER.GITHUB_RUN_ATTEMPT`. The archive check verifies matching versions, both executables, companion ID, and permission strings. Unsigned CI also uses a release-style number, because the initial signed attempt caught a mismatch that a default `1` build had hidden.

## Phone integrations

- **Apple Home:** connect from iPhone Setup; allow access and select devices/scenes. Existing Matter devices in Home use that pairing.
- **Computer:** [receiver setup](../receiver/README.md), then save address/token in the phone. Credentials use the iPhone Keychain.
- **Spotify:** create a developer app with Web API + iOS, bundle `com.yangston.wizardry`, redirect `wizardry-spotify://callback`. Register/allowlist the owner. Wizardry uses authorization code with PKCE, with only a public Client ID, never a client secret. Premium is required for playback control. API/device volume limitations remain explicit in the app.
- **Live iPhone volume:** connect Phone and leave Wizardry's native slider visible. Activate, extend past 55° yaw, twist, then lock. The bridge hosts an ordinary `MPVolumeView` instead of subclassing it, and requires actual audio-session readback before acknowledgement. This implementation fix remains experimental until physical-iPhone validation; no Shortcut or receiver is required, and locked/background phone control is unavailable. See [setup and checks](LIVE_VOLUME.md#live-iphone-volume-experimental).
- **Volume Shortcuts:** existing discrete twist mappings use user-created `Wizardry Volume Up` and `Wizardry Volume Down`; only launched while Wizardry is foreground on iPhone. Native volume/Now Playing remain available.

HomeKit and local network prompts, music authorization, Spotify login, actual Watch gestures, and accessory actions must be verified on hardware. No sensor data is uploaded by the app to a cloud service.

The Spotify developer app is now registered, its iOS bundle and redirect are saved, the owner's Spotify account is allowlisted, and the public Client ID is configured in the TestFlight environment. The user still completes Spotify authorization in the iPhone app. No client secret is embedded or required.

## Computer studio setup

1. Start the updated paired receiver and open its local dashboard. It provides **Volume**, **Live sensors**, **Record movements**, and **Map movements** pages; see the [receiver guide](../receiver/README.md).
2. Enable **Computer studio** on the foreground iPhone. Keep Wizardry visible on the Watch. Choose **Start sensors** on the computer. This monitoring subscription is independent of the command target; it does not switch Phone control to Computer or permit commands to both.
3. In **Record movements**, create a named movement and select **Record example**. Stay still while **Preparing**. Start the movement only after Watch confirmation and **Recording — move now**. Watch gesture actions are disabled during capture.
4. Choose **Stop & save**, or **Cancel** to discard. Takes have a 60-second limit and quality/interruption indicators. Confirmed recording samples are saved locally under `receiver/data/`; they are not uploaded to a cloud service.
5. **Map movements** stores custom movement/action labels for later training. Saving examples or labels does not enable trained recognition. Existing Computer/Phone discrete mappings can be edited separately with the iPhone's current-revision acknowledgement; Home target configuration stays on iPhone.

Turning off Computer studio or losing its foreground iPhone relay stops capture/monitoring; inspect interrupted-take quality before keeping an example. Dashboard access stays on the computer's loopback interface, and browser pages never receive the pairing token. Do not treat a saved recording or passing synthetic test as validated recognition.

## Known delivery history

On September 30, 2026, version **0.1.0 (2.1)** from `caaff0da6647cc1dff09f2667c31ca546d8ac2be` completed Apple processing (`VALID`) and entered internal testing (`IN_BETA_TESTING`). The owner subsequently reported it working. This is evidence for the original prototype only.

- [0.1 native validation](https://github.com/Yangston/wizardry/actions/runs/36788816769)
- [0.1 signed upload](https://github.com/Yangston/wizardry/actions/runs/36789067226)
- [App TestFlight](https://appstoreconnect.apple.com/teams/84fb843d-0ed0-46ad-bd41-9e9c4c38ce66/apps/6817949081/testflight)

## References

- [Apple: upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
- [Apple: internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers)
- [Apple: temporary autorotation](https://developer.apple.com/documentation/watchkit/wkapplication/isautorotating)
- [Apple: Double Tap](https://developer.apple.com/documentation/watchos-apps/enabling-double-tap)
- [Spotify: iOS registration](https://developer.spotify.com/documentation/ios/getting-started)
- [Spotify: development quota and Premium](https://developer.spotify.com/documentation/web-api/concepts/quota-modes)


Live computer volume, learned single-touch setup, and physical acceptance checks are described in [LIVE_VOLUME.md](LIVE_VOLUME.md). Keep AssistiveTouch single finger touch assigned to **None**; double touch runs **Activate Wizardry**. The separate twist-to-wake mechanism has been removed.
