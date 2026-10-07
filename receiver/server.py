"""Wizardry LAN receiver. Python 3.10+, no dependencies. Defaults to dry run."""
import argparse
import csv
import ctypes
import hmac
import json
import math
import os
import platform
from pathlib import Path
import secrets
import ssl
import subprocess
import time
import uuid
from live_volume import LiveVolumeProcessor
from dashboard import DashboardState, start_dashboard
from http.server import BaseHTTPRequestHandler, HTTPServer

KEY_CODES = {"volume_up": 0xAF, "volume_down": 0xAE, "mute": 0xAD,
             "play_pause": 0xB3, "next_track": 0xB0, "previous_track": 0xB1,
             "next_slide": 0x27, "previous_slide": 0x25}
ALLOWED = {"ping", *KEY_CODES}


def pairing_token_file(path):
    """Reuse an explicitly selected private token file; never rotate it on restart."""
    path = Path(path)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        token = path.read_text(encoding="ascii").strip()
        if len(token) < 16 or not token.isascii() or any(c.isspace() for c in token):
            raise ValueError("Invalid pairing token file; restore it or explicitly choose a new file")
        return token
    try:
        # Protect the empty file before writing a credential. Windows ignores
        # POSIX mode bits, so remove inherited access and grant only this user.
        if platform.system() == "Windows":
            identity = subprocess.run(["whoami", "/user", "/fo", "csv", "/nh"],
                                      check=True, capture_output=True, text=True)
            sid = next(csv.reader(identity.stdout.splitlines()))[1]
            if not sid.startswith("S-1-"):
                raise ValueError("Could not determine the current Windows user")
            subprocess.run(["icacls", str(path), "/inheritance:r", "/grant:r", f"*{sid}:(F)", "/q"],
                           check=True, capture_output=True)
        token = secrets.token_urlsafe(24)
        with os.fdopen(fd, "w", encoding="ascii") as stream:
            fd = None
            stream.write(token + "\n")
        return token
    except Exception:
        if fd is not None:
            os.close(fd)
        path.unlink()
        raise


class CommandProcessor:
    def __init__(self, token, execute=False, clock=time.time, volume_action=None, pacing_clock=None):
        if len(token) < 16:
            raise ValueError("WIZARDRY_TOKEN must contain at least 16 characters")
        self.token = token
        self.execute = execute
        self.clock = clock
        self.volume_action = volume_action or windows_volume
        self.seen = {}
        self.last_action = float("-inf")
        self.live_volume = LiveVolumeProcessor(execute=execute, clock=clock, pacing_clock=pacing_clock)
        self.dashboard = DashboardState(execute=execute, clock=clock)

    def handle_volume(self, authorization, payload):
        if not hmac.compare_digest(authorization.encode(), ("Bearer " + self.token).encode()):
            return 401, {"error": "Unauthorized"}
        if not isinstance(payload, dict):
            return 400, {"error": "Expected JSON object"}
        status, body = self.live_volume.handle(payload)
        self.dashboard.live_volume(payload.get("operation"), status, body,
                                   self.live_volume.active is not None)
        return status, body

    def handle(self, authorization, payload):
        if not hmac.compare_digest(authorization.encode(), ("Bearer " + self.token).encode()):
            return 401, {"error": "Unauthorized"}
        if not isinstance(payload, dict):
            return 400, {"error": "Expected JSON object"}
        command = payload.get("command")
        event_id = payload.get("id")
        timestamp = payload.get("timestamp")
        try:
            uuid.UUID(event_id)
        except (ValueError, TypeError, AttributeError):
            return 400, {"error": "Expected UUID id"}
        now = self.clock()
        if not isinstance(timestamp, (int, float)) or isinstance(timestamp, bool) or not math.isfinite(timestamp):
            return 400, {"error": "Expected timestamp"}
        if abs(now - timestamp) > 15:
            return 408, {"error": "Expired command; check device clocks"}
        if not isinstance(command, str) or command not in ALLOWED:
            return 400, {"error": "Unsupported command"}
        self.seen = {key: value for key, value in self.seen.items() if now - value < 30}
        if event_id in self.seen:
            return 409, {"error": "Duplicate command"}
        if command != "ping" and now - self.last_action < 0.3:
            return 429, {"error": "Too many commands"}
        self.seen[event_id] = now
        executed = False
        if command != "ping":
            self.last_action = now
            if self.execute:
                self.volume_action(command)
                executed = True
        reply = {"ok": True, "command": command, "executed": executed}
        if command == "ping":
            reply["serverTime"] = self.clock()
            reply["liveVolume"] = True
            reply["liveVolumeProtocol"] = 2
        self.dashboard.command(command, executed)
        return 200, reply


def windows_volume(command):
    if platform.system() != "Windows":
        raise RuntimeError("Volume execution is implemented only for Windows")
    key = KEY_CODES[command]
    ctypes.windll.user32.keybd_event(key, 0, 0, 0)
    ctypes.windll.user32.keybd_event(key, 0, 2, 0)


def handler_for(processor):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            if self.path not in ("/command", "/volume"):
                self.reply(404, {"error": "Not found"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if length <= 0 or length > 2048:
                    self.reply(413, {"error": "Body must be 1–2048 bytes"})
                    return
                payload = json.loads(self.rfile.read(length))
            except (ValueError, UnicodeDecodeError):
                self.reply(400, {"error": "Invalid JSON"})
                return
            try:
                dispatch = processor.handle_volume if self.path == "/volume" else processor.handle
                status, body = dispatch(self.headers.get("Authorization", ""), payload)
            except Exception:
                self.reply(500, {"error": "Command execution failed"})
                return
            if status == 200 and self.path == "/command":
                print(f"{body['command']}: {'executed' if body['executed'] else 'dry run / ping'}", flush=True)
            elif self.path == "/volume" and status != 200:
                # Status and our own bounded reason only: no request body/token.
                print(f"Live volume rejected: HTTP {status} - {body.get('error', 'Unknown error')}", flush=True)
            self.reply(status, body)

        def setup(self):
            super().setup()
            self.connection.settimeout(5)

        def reply(self, status, body):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            pass  # Never log credentials or request bodies.
    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1", help="Use 0.0.0.0 to receive LAN requests")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--execute", action="store_true", help="Execute allowed Windows media or presentation keys")
    parser.add_argument("--no-ui", action="store_true", help="Run without opening the local visual display")
    parser.add_argument("--cert", help="Optional trusted TLS certificate PEM")
    parser.add_argument("--key", help="TLS private key PEM")
    pairing = parser.add_mutually_exclusive_group()
    pairing.add_argument("--pair", action="store_true", help="Generate a NEW session-only token on every start and show it locally")
    pairing.add_argument("--token-file", help="Create/reuse a private pairing token file and show its token locally; survives restarts")
    args = parser.parse_args()
    if bool(args.cert) != bool(args.key):
        parser.error("Pass both --cert and --key for HTTPS")
    if args.execute and platform.system() != "Windows":
        parser.error("--execute requires Windows; use dry run on the Pi or other systems")
    try:
        token = (pairing_token_file(args.token_file) if args.token_file else
                 secrets.token_urlsafe(24) if args.pair else os.environ.get("WIZARDRY_TOKEN", ""))
        processor = CommandProcessor(token, args.execute)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        # Avoid including token-file contents or subprocess output in errors.
        parser.error(str(error) if not args.token_file else "Could not load/create the private pairing token file. Check the file and its permissions; it was not rotated.")
    server = HTTPServer((args.host, args.port), handler_for(processor))
    if args.cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.cert, args.key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    if args.pair or args.token_file:
        print("Pairing token (enter only in Wizardry on your iPhone): " + token, flush=True)
        if args.pair:
            print("Session-only pairing: restarting with --pair changes this token. Use --token-file receiver/.pairing-token to keep pairing across restarts.", flush=True)
        else:
            print("Saved pairing: use the same --token-file on future starts. Keep this file private.", flush=True)
    scheme = "https" if args.cert else "http"
    print(f"Wizardry listening at {scheme}://{args.host}:{args.port}; execute={args.execute}", flush=True)
    dashboard_server = None
    try:
        if not args.no_ui:
            try:
                dashboard_server = start_dashboard(processor.dashboard)
            except OSError:
                print("Could not start the visual display; receiver is still available.", flush=True)
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        if dashboard_server:
            dashboard_server.shutdown()
            dashboard_server.server_close()


if __name__ == "__main__":
    main()
