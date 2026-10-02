"""Read-only, loopback-only receiver display. Never carries pairing credentials."""
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading
import time
import webbrowser


class DashboardState:
    def __init__(self, execute=False, clock=time.time):
        self.execute = execute
        self.clock = clock
        self.lock = threading.Lock()
        self.started = clock()
        self.contact = None
        self.volume = None
        self.anchor = None
        self.volume_at = None
        self.phase = "waiting"
        self.accepted = 0
        self.events = deque(maxlen=24)
        self.history = deque(maxlen=320)
        self.event_id = 0

    def _event(self, label, kind="action"):
        self.event_id += 1
        self.events.appendleft({"id": self.event_id, "time": self.clock(),
                                "label": label, "kind": kind})

    def command(self, command, executed):
        with self.lock:
            self.contact = self.clock()
            if command == "ping":
                return
            self.accepted += 1
            self._event(command.replace("_", " ").capitalize() +
                        (" · executed" if executed else " · dry run"))

    def live_volume(self, operation, status, body, active):
        with self.lock:
            self.contact = self.clock()
            if status != 200:
                self._event(f"Volume request rejected · HTTP {status}", "error")
                if self.phase == "live" and not active:
                    self.phase = "interrupted"
                return
            self.accepted += 1
            self.volume = body["volume"]
            self.volume_at = self.clock()
            if operation == "begin":
                self.anchor = self.volume
                self.phase = "live"
                self.history.clear()
                self._event("Live volume started", "volume")
            elif operation == "end":
                self.phase = "locked"
                self._event("Final volume confirmed · session closed", "lock")
            if (not self.history or operation != "update" or
                    self.volume_at - self.history[-1]["time"] >= 0.1):
                self.history.append({"time": self.volume_at, "volume": self.volume})

    def snapshot(self):
        with self.lock:
            now = self.clock()
            phase = self.phase
            if phase == "live" and now - self.volume_at > 6:
                phase = "interrupted"
            return {"execute": self.execute, "serverTime": now,
                    "uptime": max(0, now - self.started), "phase": phase,
                    "lastContact": self.contact, "volume": self.volume,
                    "anchor": self.anchor, "volumeAt": self.volume_at,
                    "accepted": self.accepted, "events": list(self.events),
                    "history": list(self.history)}


def dashboard_handler(state):
    assets = Path(__file__).with_name("ui")
    routes = {"/": ("index.html", "text/html; charset=utf-8"),
              "/dashboard.css": ("dashboard.css", "text/css; charset=utf-8"),
              "/dashboard.js": ("dashboard.js", "text/javascript; charset=utf-8")}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            # A loopback bind plus exact Host/Origin checks prevents other LAN
            # clients and foreign web pages (including DNS rebinding) reading it.
            host = f"127.0.0.1:{self.server.server_port}"
            origin = self.headers.get("Origin")
            if (self.client_address[0] != "127.0.0.1" or
                    self.headers.get("Host") != host or
                    origin not in (None, f"http://{host}") or
                    self.headers.get("Sec-Fetch-Site") == "cross-site"):
                self.respond(403, b"Local display only", "text/plain")
                return
            if self.path == "/status":
                self.respond(200, json.dumps(state.snapshot()).encode(), "application/json")
            elif self.path in routes:
                name, content_type = routes[self.path]
                self.respond(200, (assets / name).read_bytes(), content_type)
            else:
                self.respond(404, b"Not found", "text/plain")

        def setup(self):
            super().setup()
            self.connection.settimeout(2)

        def respond(self, status, data, content_type):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Security-Policy", "default-src 'self'; object-src 'none'; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            pass
    return Handler


def start_dashboard(state, open_browser=True):
    server = ThreadingHTTPServer(("127.0.0.1", 0), dashboard_handler(state))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{server.server_port}/"
    print(f"Wizardry visual display: {url}", flush=True)
    if open_browser:
        try:
            if not webbrowser.open(url):
                print("Open the visual display URL above in your browser.", flush=True)
        except (webbrowser.Error, OSError):
            print("Open the visual display URL above in your browser.", flush=True)
    return server
