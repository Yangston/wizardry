# Computer receiver

Python 3.10+; no dependencies. Run on your Windows computer:

```powershell
python receiver/server.py --host 0.0.0.0 --pair
```

This starts a **dry-run** receiver and prints a fresh, session-only pairing token locally. In the iPhone Wizardry app, Setup → Computer receiver, enter `http://YOUR-PC-LAN-IP:8765` and that token, then Save pairing & test connection. Use your computer's LAN IPv4 address (`ipconfig`), not `0.0.0.0` or `localhost`. Both devices need to reach the same private LAN. Allow Python through Windows Firewall on the private network if prompted.

To actually execute media/presentation keys, stop the receiver and restart:

```powershell
python receiver/server.py --host 0.0.0.0 --pair --execute
```

Enter the newly generated token on the phone. For a stable token across restarts, set `WIZARDRY_TOKEN` to a private random value of at least 16 characters and omit `--pair`. Never commit or share tokens.

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

The authenticated `/volume` endpoint reads/sets absolute Windows Core Audio volume through ordered begin/update/end sessions. Run the updated receiver for Watch live height control. Execute mode uses the current default multimedia output; dry run simulates volume without audio changes. No extra dependencies are required. Live requests expire after one second and session updates are limited to five per second. A final end request closes the session, preventing delayed updates. See [live-volume setup and protocol](../docs/LIVE_VOLUME.md).
