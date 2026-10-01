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

The team API key must manage certificates/profiles as well as upload. App Manager works for the established setup. The API key and distribution private key have different purposes. Never print them, commit them, paste them into chat, or regenerate the certificate key on every build. GitHub cannot reveal saved secret values.

The signing workflow fetches profiles for both bundles. After enabling a capability such as HomeKit, ensure the selected profile contains the entitlement; a stale profile must be regenerated, not worked around by stripping the entitlement.

Both Info.plists explicitly bind `CFBundleVersion` to `$(CURRENT_PROJECT_VERSION)` and `CFBundleShortVersionString` to `$(MARKETING_VERSION)`. Build numbers are `GITHUB_RUN_NUMBER.GITHUB_RUN_ATTEMPT`. The archive check verifies matching versions, both executables, companion ID, and permission strings. Unsigned CI also uses a release-style number, because the initial signed attempt caught a mismatch that a default `1` build had hidden.

## Phone integrations

- **Apple Home:** connect from iPhone Setup; allow access and select devices/scenes. Existing Matter devices in Home use that pairing.
- **Computer:** [receiver setup](../receiver/README.md), then save address/token in the phone. Credentials use the iPhone Keychain.
- **Spotify:** create a developer app with Web API + iOS, bundle `com.yangston.wizardry`, redirect `wizardry-spotify://callback`. Register/allowlist the owner. Wizardry uses authorization code with PKCE, with only a public Client ID, never a client secret. Premium is required for playback control. API/device volume limitations remain explicit in the app.
- **Volume Shortcuts:** optional user-created `Wizardry Volume Up` and `Wizardry Volume Down`; only launched while Wizardry is foreground on iPhone. Native volume/Now Playing remain available.

HomeKit and local network prompts, music authorization, Spotify login, actual Watch gestures, and accessory actions must be verified on hardware. No sensor data is uploaded by the app to a cloud service.

## Known delivery history

On September 30, 2026, version **0.1.0 (2.1)** from `caaff0da6647cc1dff09f2667c31ca546d8ac2be` completed Apple processing (`VALID`) and entered internal testing (`IN_BETA_TESTING`). The owner subsequently reported it working. This is evidence for the original prototype only.

- [0.1 native validation](https://github.com/Yangston/wizardry/actions/runs/36788816769)
- [0.1 signed upload](https://github.com/Yangston/wizardry/actions/runs/36789067226)
- [App TestFlight](https://appstoreconnect.apple.com/teams/84fb843d-0ed0-46ad-bd41-9e9c4c38ce66/apps/6817949081/testflight)

## References

- [Apple: upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
- [Apple: internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers)
- [Apple: extended runtime sessions](https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions)
- [Apple: Double Tap](https://developer.apple.com/documentation/watchos-apps/enabling-double-tap)
- [Spotify: iOS registration](https://developer.spotify.com/documentation/ios/getting-started)
- [Spotify: development quota and Premium](https://developer.spotify.com/documentation/web-api/concepts/quota-modes)
