# Computer receiver

Python 3.10+; no dependencies. Run on your Windows computer:

Double-click **Start-Wizardry.cmd** in the repository root to start the dry-run receiver and open its dashboard. This uses the same saved `receiver/.pairing-token` on every start. To enable actual computer controls, stop the current receiver and run `Start-Wizardry.cmd --execute` from a terminal in the repository root. Sensor graphs and recordings are available in either mode.

The equivalent manual command is:

```powershell
python receiver/server.py --host 0.0.0.0 --token-file receiver/.pairing-token
```

This starts a **dry-run** receiver and prints a pairing token locally. On the first run it creates a private token file; later runs reuse it. In the iPhone Wizardry app, Setup → Computer receiver, enter `http://YOUR-PC-LAN-IP:8765` and that token, then Save pairing & test connection. Use your computer's LAN IPv4 address (`ipconfig`), not `0.0.0.0` or `localhost`. Both devices need to reach the same private LAN. Allow Python through Windows Firewall on the private network if prompted.

The receiver also opens a **live visual display** in your computer's browser: a volume dial, a 30-second confirmed-volume chart, gesture guidance, and recent accepted commands. Use **Full screen** for a larger display or **Preview visuals** for a clearly labeled animation that sends no commands. The navigation also opens **Live sensors**, **Record movements**, and **Map movements**. A confirmed final volume closes the session and shows **Locked**; a lost/expired session shows **Stopped · unconfirmed**. Dry-run volume values are explicitly simulated. Live sensor plots show received Watch samples only.

The display runs on a separate, local-only address printed as `Wizardry visual display: http://127.0.0.1:PORT/`. It never contains your pairing token and cannot be opened from another device. If the browser does not open, paste that printed URL into a browser on the PC. Add `--no-ui` for console-only use. Restart the receiver to get the new display; saved pairing is preserved with the same `--token-file`.

To actually execute media/presentation keys, stop the receiver and restart:

```powershell
python receiver/server.py --host 0.0.0.0 --token-file receiver/.pairing-token --execute
```

The same token remains valid when switching to execute mode. Keep using the same file path, and keep the file private: it is excluded from Git and created with current-user-only access on Windows (mode 0600 elsewhere). Other file names must also be excluded from Git. To revoke pairing, stop the receiver, delete the token file, and restart to create a new token; enter that new token on the phone.

`--pair` is still available for **session-only** pairing: it generates a new token on every start, including a restart with `--execute`. It cannot be combined with `--token-file`. Alternatively, set `WIZARDRY_TOKEN` to a private random value of at least 16 characters and omit both options. Never commit or share tokens.

### HTTP 401 when pairing

A 401 means the phone reached a receiver, but its supplied token does not match. Enter only the token printed by the **currently running** receiver, without the console label, quotes, or spaces. Check that the phone's receiver URL points to that PC. If you restarted with `--pair`, the previously saved token is no longer valid. To prevent this on later restarts, stop that receiver and use the `--token-file` command above, then save its printed token on iPhone once.

| Command | Windows effect |
|---|---|
| `ping` | Acknowledgement only |
| `volume_up`, `volume_down` | System media-volume key |
| `mute` | Toggle mute |
| `play_pause` | Media play/pause key |
| `next_track`, `previous_track` | Media track key |
| `next_slide`, `previous_slide` | Right/left arrow in the focused application |

There is no arbitrary command or shell execution. UUID replay prevention, token authentication, a 15-second receiver expiry, and rate limiting remain enforced. The phone accepts watch commands only within five seconds and does not queue or retry them. Phone “dry run” status means acknowledged, not executed.

HTTP is for a trusted private LAN; optional `--cert certificate.pem --key private.key` serves HTTPS with a certificate trusted by the phone. Do not expose this listener to the internet. Pi/macOS/Linux can run dry-run mode; execution in this version is implemented for Windows.

Run tests: `python -m unittest discover -s receiver -v`.


## Live volume

The authenticated `/volume` endpoint reads/sets absolute Windows Core Audio volume through ordered begin/update/end sessions. Execute mode uses the current default multimedia output; dry run simulates volume without audio changes. No extra dependencies are required. Live requests expire after one second. A monotonic token bucket permits 50 updates per second with a burst capacity of four, independently of the wall clock used for expiry. A final end request bypasses the update limiter and closes the session before its write, preventing later updates. Legacy 20 Hz clients remain accepted. See [live-volume setup and protocol](../docs/LIVE_VOLUME.md).

Authenticated `ping` advertises `liveVolumeProtocol: 2`, and successful begin replies include `transportVersion: 2`. The new Watch transport requires the updated phone and receiver; update both apps and restart this receiver together. Watch sends are bounded to four outstanding updates, and the phone executes one write at a time while retaining only the newest waiting target. Superseded targets are never reported as applied volume. The configured 50 Hz rate is a transport limit, not a physical-output performance claim.

The authenticated `ping` and volume replies include receiver time. The phone translates live timestamps into that clock domain after checking the original one-second Watch/phone deadline. This supports a PC clock that differs from the phone without extending expiry or replaying commands. Failed live requests log an HTTP status and reason, never pairing tokens or request bodies. Restart the receiver after updating its files; `--token-file` preserves pairing, while `--pair` requires saving the newly generated token on iPhone.

Holding the Watch still does not end a healthy live-volume session. The Watch sends an unchanged-volume heartbeat each second, while the receiver retains its six-second missing-request watchdog. This watchdog detects interrupted delivery, not absence of hand movement. Manual lock, sensing/transport failures, explicit interruptions, and the Watch's ten-minute interaction cap remain enforced.

## Motion studio

Keep Wizardry open on iPhone and Watch. Connect the saved computer receiver and enable **Computer studio** on iPhone, then open **Live sensors** in the computer dashboard and click **Start sensors**. The studio link is independent of the selected control target: watching sensor graphs does not switch phone volume to computer volume. Closing the browser stops the stream request after five seconds unless a bounded recording is running. **Stop sensors** stops the request immediately; sensor delivery can take one phone polling interval to settle.

The dashboard plots user acceleration, raw accelerometer, rotation rate, gravity, roll/pitch/yaw, attitude quaternion, magnetic field, and magnetic accuracy when supplied by the Watch. Missing channels stay visibly unavailable. Raw accelerometer and fused motion timestamps are retained separately. Capture requests 100 Hz; the UI reports the rate computed from actual received sensor timestamps, not a hardware guarantee. Canvas redraw is capped at 20 Hz and only plotting may omit samples; recording storage retains every accepted frame. Gaps over 40 ms, missing batches, sender-reported drops, and stale status remain visible.

On **Record movements**:

1. Enter a movement name and click **Create**.
2. Start sensors and wait for fresh samples. Click **Record example**.
3. Wait for **Preparing — hold still** to change to **Recording — move now**. The Watch must confirm recording mode before samples enter the example. Watch gesture actions are paused during capture.
4. Perform one example, then click **Stop & save**. Repeat to collect several examples. **Cancel** discards the in-progress example.

Each recording is capped at 60 seconds and 12,000 samples. If the stream stalls, sensing restarts, sender drops samples, required optional channels are missing, or the Watch never confirms capture mode, the example is saved with explicit **Partial** quality reasons. Partial recordings are not presented as ready training data. Existing recordings are never automatically trained, replayed, or executed.

Movement names, inactive mappings, and recording summaries persist in `receiver/data/library.json`. Full recordings are separate UUID-named JSON files in `receiver/data/`; use **Download original samples** to export one. The directory is excluded from Git. Writes replace files atomically, and an unreadable existing library is preserved instead of silently replaced. Store up to 250 named movements and 5,000 recordings. Receiver restarts preserve the library and stop sensor streaming.

**Map movements** has two sections. Existing Computer and Phone gesture mappings are edited against the iPhone's current configuration revision and are confirmed only after iPhone acknowledges the update. No action is executed by saving a mapping. Concurrent changes are rejected instead of overwriting newer settings. Edit Home devices and scenes on iPhone. Custom movement mappings are local plans only and remain **Untrained · inactive** until a separate future training/deployment feature exists.

The LAN `/studio` and `/telemetry` endpoints require the existing bearer pairing credential and expire requests after five seconds; authenticated ping advertises `studioProtocol: 1`. Telemetry has an ordered session UUID and batch sequence, a maximum of 200 samples and a 256 KiB body limit. Duplicate, reordered, expired, nonfinite, and closed-session batches are rejected without replay. The local browser never receives the pairing credential: its writes require loopback access, exact Host/Origin validation, JSON, and a separate per-process CSRF token. There are no arbitrary command or shell mappings.

These checks and synthetic browser tests do not establish physical Watch sample rate, recognition quality, battery use, or suspension behavior. Real Watch → iPhone → PC delivery and the recording-mode acknowledgement must still be checked on hardware.
