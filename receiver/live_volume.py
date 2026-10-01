"""Authenticated by server.py before dispatch. Short-lived ordered volume sessions."""
import math
import uuid
from windows_audio import WindowsAudio


class LiveVolumeProcessor:
    def __init__(self, execute=False, clock=None, audio=None):
        import time
        self.execute = execute
        self.clock = clock or time.time
        self.audio = audio or WindowsAudio()
        self.active = None
        self.closed = {}
        self.seen = {}
        self.dry_volume = 0.5

    def handle(self, payload):
        now = self.clock()
        self.closed = {k: t for k, t in self.closed.items() if now-t < 1800}
        self.seen = {k: t for k, t in self.seen.items() if now-t < 30}
        if self.active and now-self.active["last"] > 6:
            self.closed[self.active["id"]] = now
            self.active = None
        try:
            event_id = str(uuid.UUID(payload["id"]))
            session_id = str(uuid.UUID(payload["sessionID"]))
            operation = payload["operation"]
            sequence = payload["sequence"]
            timestamp = payload["createdAt"]
            revision = payload["revision"]
        except (KeyError, TypeError, ValueError, AttributeError):
            return 400, {"error": "Malformed volume request"}
        if operation not in ("begin", "update", "end") or not isinstance(revision, str) or not revision or len(revision) > 128:
            return 400, {"error": "Invalid operation or revision"}
        if type(sequence) is not int or sequence < 0 or sequence > 2**31-1:
            return 400, {"error": "Invalid sequence"}
        if type(timestamp) not in (int, float) or not math.isfinite(timestamp):
            return 400, {"error": "Invalid timestamp"}
        if timestamp > now+0.1 or now-timestamp > 1:
            age_ms = round((now-timestamp)*1000)
            return 408, {"error": f"Live volume request expired (receiver minus request: {age_ms} ms)",
                         "request_age_ms": age_ms}
        target = payload.get("target")
        if operation == "begin":
            if sequence != 0 or target is not None:
                return 400, {"error": "Begin must use sequence zero and no target"}
        elif sequence == 0 or type(target) not in (int, float) or not math.isfinite(target) or not 0 <= target <= 1:
            return 400, {"error": "Expected normalized volume target"}
        if event_id in self.seen or session_id in self.closed:
            return 409, {"error": "Duplicate or closed volume session"}
        if operation != "begin":
            if not self.active or self.active["id"] != session_id or self.active["revision"] != revision or sequence <= self.active["sequence"]:
                return 409, {"error": "Unknown session or older sequence"}
            if operation == "update" and now-self.active["update"] < 0.049:
                return 429, {"error": "Maximum twenty volume updates per second"}
        elif self.active and self.active["id"] == session_id:
            return 409, {"error": "Session already begun"}
        self.seen[event_id] = now
        try:
            if operation == "begin":
                if self.active:
                    self.closed[self.active["id"]] = now
                    self.active = None
                volume, device = self.audio.read() if self.execute else (self.dry_volume, "dry-run")
                self.active = {"id": session_id, "revision": revision, "sequence": 0,
                               "last": now, "update": float("-inf"), "device": device}
            else:
                self.active["sequence"] = sequence
                self.active["last"] = now
                if operation == "update":
                    self.active["update"] = now
                # Close before I/O so even a failed final set cannot reopen it.
                device = self.active["device"]
                if operation == "end":
                    self.closed[session_id] = now
                    self.active = None
                volume = self.audio.set(target, device) if self.execute else target
                if not self.execute:
                    self.dry_volume = volume
        except (OSError, RuntimeError) as error:
            self.closed[session_id] = now
            self.active = None
            return 503, {"error": str(error)}
        return 200, {"outcome": "executed" if self.execute else "dryRun", "message": "Locked" if operation == "end" else "Volume accepted",
                     "sessionID": session_id, "sequence": sequence, "volume": volume, "serverTime": self.clock()}
