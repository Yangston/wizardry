"""Wizardry LAN receiver. Python 3.10+, no dependencies. Defaults to dry run."""
import argparse
import ctypes
import hmac
import json
import math
import os
import platform
import ssl
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

ALLOWED = {"ping", "volume_up", "volume_down"}


class CommandProcessor:
    def __init__(self, token, execute=False, clock=time.time, volume_action=None):
        if len(token) < 16:
            raise ValueError("WIZARDRY_TOKEN must contain at least 16 characters")
        self.token = token
        self.execute = execute
        self.clock = clock
        self.volume_action = volume_action or windows_volume
        self.seen = {}
        self.last_action = float("-inf")

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
        return 200, {"ok": True, "command": command, "executed": executed}


def windows_volume(command):
    if platform.system() != "Windows":
        raise RuntimeError("Volume execution is implemented only for Windows")
    key = 0xAF if command == "volume_up" else 0xAE
    ctypes.windll.user32.keybd_event(key, 0, 0, 0)
    ctypes.windll.user32.keybd_event(key, 0, 2, 0)


def handler_for(processor):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            if self.path != "/command":
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
                status, body = processor.handle(self.headers.get("Authorization", ""), payload)
            except Exception:
                self.reply(500, {"error": "Command execution failed"})
                return
            if status == 200:
                print(f"{body['command']}: {'executed' if body['executed'] else 'dry run / ping'}", flush=True)
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
    parser.add_argument("--execute", action="store_true", help="Actually change Windows volume")
    parser.add_argument("--cert", help="Optional trusted TLS certificate PEM")
    parser.add_argument("--key", help="TLS private key PEM")
    args = parser.parse_args()
    if bool(args.cert) != bool(args.key):
        parser.error("Pass both --cert and --key for HTTPS")
    if args.execute and platform.system() != "Windows":
        parser.error("--execute requires Windows; use dry run on the Pi or other systems")
    try:
        processor = CommandProcessor(os.environ.get("WIZARDRY_TOKEN", ""), args.execute)
    except ValueError as error:
        parser.error(str(error))
    server = HTTPServer((args.host, args.port), handler_for(processor))
    if args.cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.cert, args.key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    scheme = "https" if args.cert else "http"
    print(f"Wizardry listening at {scheme}://{args.host}:{args.port}; execute={args.execute}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
