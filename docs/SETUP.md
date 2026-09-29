# Windows → GitHub Actions → TestFlight → Apple Watch

## 1. Prerequisites

- Windows PC with Git and VS Code/Codex.
- Apple Watch running watchOS 10+ and a paired iPhone running iOS 17+.
- GitHub access to Yangston/wizardry.
- Apple Developer Program membership for TestFlight (US$99/year or local pricing). You can prove the unsigned build first. Enrollment verification may take time.
- TestFlight installed on the paired iPhone.

You do not need to own or borrow a Mac. GitHub runs Xcode on a macOS build runner.

## 2. Check the unsigned build

Open the repository's **Actions → Build and test**. Pushes to main and pull requests run it automatically; it can also be run manually. It tests the detector, compiles the watch simulator app, creates an unsigned device archive, checks its watch-only packaging, and tests the receiver on Windows.

The build selects Xcode 26.3 on `macos-15`. If GitHub retires that image/toolchain, update both workflows to an available Xcode path and check watchOS/iOS compatibility. XcodeGen is installed using Homebrew; its actual version is visible in the job logs.

This unsigned archive cannot be installed on your physical watch.

## 3. Enroll and create the Apple app record

Enroll as an individual at https://developer.apple.com/programs/enroll/ or using the Apple Developer app on your iPhone. Wait until membership is active.

In Certificates, Identifiers & Profiles, register these explicit App IDs (platform iOS, iPadOS, macOS, tvOS, watchOS as presented by Apple):

| Target | Default bundle identifier |
|---|---|
| Distribution container | `com.yangston.wizardry` |
| Watch application | `com.yangston.wizardry.watchkitapp` |

These are proposed identifiers, not an assertion that they have already been registered. If unavailable, choose your own prefix and set the `BUNDLE_ID` variable below; keep the `.watchkitapp` suffix for the watch.

At https://appstoreconnect.apple.com/ choose **Apps → + → New App**:

- Platform: **iOS** (Apple categorizes watch-only apps here).
- Name: Wizardry (or an available name).
- Primary language: your choice.
- Bundle ID: the **container** identifier above.
- SKU: `wizardry-001` or another unique internal identifier.

Record the numeric **Apple ID** in App Information as `APP_STORE_APP_ID`. Record your **Team ID** from Apple Developer membership details as `APPLE_TEAM_ID`.

## 4. Create API and certificate keys

In App Store Connect, request API access if prompted, then open **Users and Access → Integrations → App Store Connect API → Team Keys → Generate API Key**. For this workflow's automatic creation of distribution signing assets, use a dedicated team key with Admin access. This grants broad account access; keep it exclusively in the deployment environment. An upload-only key is not sufficient for the automatic certificate/provisioning setup.

Download the `.p8` key once, and note its Key ID and Issuer ID. This authenticates the build to Apple.

Separately generate a persistent RSA signing-certificate private key on Windows. In **Git Bash** (with OpenSSL installed):

```bash
umask 077
mkdir -p "$HOME/wizardry-private"
openssl genrsa -out "$HOME/wizardry-private/distribution.pem" 2048
```

Keep that file outside the repository. Reuse the same certificate key across builds; generating a new one each time can exhaust Apple's certificate limit. The `.p8` API key and `distribution.pem` are different keys serving different purposes.

## 5. Configure GitHub

Create an environment named **testflight** under **Settings → Environments**. Under that environment, add the following secrets. Alternatively, repository Actions secrets are available to the job too.

| Secret | Value |
|---|---|
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID for the team API key |
| `APP_STORE_CONNECT_KEY_IDENTIFIER` | API Key ID |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Entire `.p8` contents, including BEGIN/END lines |
| `CERTIFICATE_PRIVATE_KEY` | Entire `distribution.pem` contents, including BEGIN/END lines |

Add environment or repository Actions **variables**:

| Variable | Value |
|---|---|
| `APPLE_TEAM_ID` | Your Apple Developer Team ID |
| `APP_STORE_APP_ID` | Numeric Apple ID of the container's App Store Connect record |
| `BUNDLE_ID` | Optional; defaults to `com.yangston.wizardry` |

Paste secrets directly into GitHub, not into a chat, source file, issue, or build log. Restrict the deployment environment to your trusted main branch.

## 6. Upload

Open **Actions → Upload to TestFlight → Run workflow → main**. The workflow checks configuration names without exposing values, tests the detector, generates the project, fetches/creates profiles for both targets, signs, archives, validates packaging, exports, and uploads.

Build numbers use `GITHUB_RUN_NUMBER.GITHUB_RUN_ATTEMPT` for this workflow. Keep this workflow's history, and adjust versioning if uploading independently with another tool.

No App Store submission or external tester invitation is performed. An upload still needs Apple processing and potentially export-compliance answers before it can be installed. The job does not automatically create tester groups.

## 7. Install

In App Store Connect, open **Wizardry → TestFlight**. Answer any required compliance questions accurately (this prototype uses standard OS networking encryption, if HTTPS is configured). Add yourself to an **internal testing group** and assign the processed build. Accept the invitation in TestFlight on your paired iPhone and tap Install for the watch-only app.

Internal testing does not require publishing the app publicly. Builds expire 90 days after upload; upload a new build before expiry. A simulator or unsigned app artifact is not a substitute for the signed TestFlight installation.

## 8. Verify on your wrist

Use the checklist in README.md. Start with sensors and haptics; then follow receiver/README.md for the optional LAN control test. Stop/Start establishes a fresh neutral pose. The app deliberately pauses on inactive/background transitions.

## Troubleshooting

| Symptom | Check |
|---|---|
| Signing preflight fails | Missing secret/variable names are listed in the log. |
| Apple API returns 403 | Team-key permissions and membership; certificates/profiles need more access than uploading. |
| App ID/profile mismatch | Container and watch IDs must match the generated project; set BUNDLE_ID before signing. |
| No installable build | Wait for processing, check compliance, group assignment, watchOS version, and paired iPhone. |
| No sensor data in simulator | Expected: test physical motion on the watch. |
| Gesture never fires | Check relative-roll display; rotate enough and hold briefly; recalibrate with Stop/Start. |
| Only first gesture fires | Return to the original pose within about 9° before the next rotation. |
| Receiver not reachable | Computer LAN IPv4, private firewall rule, same network, no guest/client isolation, server still running. |

## Sources

- https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/
- https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/
- https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/
- https://testflight.apple.com/
- https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications
- https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md
- https://docs.codemagic.io/knowledge-codemagic/codemagic-cli-tools/

Setup is documented; Apple account enrollment, key creation, and hardware installation must be completed by the account/device owner.
