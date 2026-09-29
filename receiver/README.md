# Computer receiver

Python 3.10+; standard library only. Supports dry-run testing anywhere and actual volume keys on Windows. The Pi can host a later device router; no lights integration is claimed here.

## Start on Windows

In PowerShell, from the repository root:

```powershell
$env:WIZARDRY_TOKEN = python -c "import secrets; print(secrets.token_hex(12))"
$env:WIZARDRY_TOKEN
python receiver/server.py --host 0.0.0.0
```

The token is shown only in your local terminal so you can enter it on the watch. Find your computer's **LAN IPv4 address** with `ipconfig`. If Windows Firewall prompts, permit access on your trusted **Private** network only. Do not expose this port on the internet.

On the watch, open **Computer control**:

1. Set the server URL to `http://YOUR-PC-IP:8765` (not `localhost`, not `0.0.0.0`, and without `/command`).
2. Enter the same token; use the paired iPhone keyboard prompt if available.
3. Tap **Send test command**. Expect the terminal to report `ping`, and the watch to show `Received (dry run)`.
4. Go back to the main screen, tap Start, then enable **Gestures control volume** in Computer control and return to the main screen. The toggle resets when the app becomes inactive.

To actually change volume, stop the receiver with Ctrl+C and restart in the **same PowerShell window**, preserving the token:

```powershell
python receiver/server.py --host 0.0.0.0 --execute
```

Rotate + sends one volume-up key; Rotate − sends one volume-down key. The main screen's haptic confirms detection; the Computer screen confirms receipt/execution. Network requests time out and are not queued for later replay.

## Networking and privacy

Both devices must reach the same LAN. watchOS may route requests through its paired iPhone or Wi-Fi; guest Wi-Fi isolation and VPNs can prevent LAN access. Verify on your own setup. Plain HTTP is for trusted-LAN prototyping and carries the token unencrypted. For HTTPS, use `--cert certificate.pem --key private-key.pem` and a hostname/certificate trusted by the watch; self-signed certificates are not silently accepted. The watch's HTTP exception should be removed when moving to an HTTPS-only product.

The server only accepts ping/volume commands, validates bearer tokens, rejects requests older/newer than 15 seconds, deduplicates IDs for 30 seconds, and rate-limits volume actions. It never executes arbitrary shell commands. Clocks must be synchronized. Token entry is session-only on the watch; restart requires entering it again.

## Test

```powershell
python -m unittest discover -s receiver -v
```

Tests verify authentication, expiry, command allowlisting, deduplication, rate limiting, dry-run behavior, and a real HTTP request. Actual Windows audio changes require a logged-in desktop session and must be checked manually.
