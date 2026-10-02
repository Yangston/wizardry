# Computer receiver

Python 3.10+; no dependencies. Run on your Windows computer:

```powershell
python receiver/server.py --host 0.0.0.0 --token-file receiver/.pairing-token
```

This starts a **dry-run** receiver and prints a pairing token locally. On the first run it creates a private token file; later runs reuse it. In the iPhone Wizardry app, Setup → Computer receiver, enter `http://YOUR-PC-LAN-IP:8765` and that token, then Save pairing & test connection. Use your computer's LAN IPv4 address (`ipconfig`), not `0.0.0.0` or `localhost`. Both devices need to reach the same private LAN. Allow Python through Windows Firewall on the private network if prompted.

The receiver also opens a **live visual display** in your computer's browser: a volume dial, a 30-second confirmed-volume chart, gesture guidance, and recent accepted commands. Use **Full screen** for a larger display or **Preview visuals** for a clearly labeled animation that sends no commands. The display shows receiver activity; Watch activation, raw wrist motion, and tap recognition stay on the Watch/iPhone. A confirmed final volume closes the session and shows **Locked**; a lost/expired session shows **Stopped · unconfirmed**. Dry-run values are explicitly simulated.

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

The authenticated `/volume` endpoint reads/sets absolute Windows Core Audio volume through ordered begin/update/end sessions. Run the updated receiver for Watch live height control. Execute mode uses the current default multimedia output; dry run simulates volume without audio changes. No extra dependencies are required. Live requests expire after one second and session updates are limited to twenty per second. A final end request closes the session, preventing delayed updates. Update both apps and restart this receiver together so the Watch and receiver use the same update limit. See [live-volume setup and protocol](../docs/LIVE_VOLUME.md).

The authenticated `ping` and volume replies include receiver time. The phone translates live timestamps into that clock domain after checking the original one-second Watch/phone deadline. This supports a PC clock that differs from the phone without extending expiry or replaying commands. Failed live requests log an HTTP status and reason, never pairing tokens or request bodies. Restart the receiver after updating its files; `--token-file` preserves pairing, while `--pair` requires saving the newly generated token on iPhone.
