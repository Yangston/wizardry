"""Bounded motion capture and mapping metadata. Never executes recorded actions."""
from collections import deque
import copy
import json
import math
from pathlib import Path
import threading
import time
import uuid


GESTURES = {"rollPositive": "Twist +", "rollNegative": "Twist -", "pitchUp": "Tilt up",
            "pitchDown": "Tilt down", "shake": "Double shake"}
ACTIONS = {"haptic": "Watch - Haptic only", "volumeUp": "Computer - Volume up",
           "volumeDown": "Computer - Volume down", "mute": "Computer - Mute",
           "playPause": "Computer - Play / pause", "nextTrack": "Computer - Next track",
           "previousTrack": "Computer - Previous track", "nextSlide": "Computer - Next slide",
           "previousSlide": "Computer - Previous slide", "phonePlayPause": "iPhone - Music play / pause",
           "phoneNext": "iPhone - Music next", "phonePrevious": "iPhone - Music previous",
           "phonePing": "iPhone - Locator chime", "shortcut": "iPhone - Shortcut",
           "lightOn": "Home - On", "lightOff": "Home - Off", "lightToggle": "Home - Toggle",
           "homeScene": "Home - Scene", "spotifyPlayPause": "Spotify - Play / pause",
           "spotifyNext": "Spotify - Next", "spotifyPrevious": "Spotify - Previous",
           "spotifyVolumeUp": "Spotify - Volume up", "spotifyVolumeDown": "Spotify - Volume down"}
PROFILE_ACTIONS = {
    "computer": {"haptic", "volumeUp", "volumeDown", "mute", "playPause", "nextTrack", "previousTrack", "nextSlide", "previousSlide"},
    "phone": {"haptic", "phonePlayPause", "phoneNext", "phonePrevious", "phonePing", "shortcut", "spotifyPlayPause",
              "spotifyNext", "spotifyPrevious", "spotifyVolumeUp", "spotifyVolumeDown"}}
CHANNELS = ("ax", "ay", "az", "rx", "ry", "rz", "gx", "gy", "gz", "roll", "pitch", "yaw")
OPTIONAL_CHANNELS = ("rawAx", "rawAy", "rawAz", "qx", "qy", "qz", "qw", "mx", "my", "mz",
                     "magneticAccuracy", "rawTime", "hz")


def finite(value):
    try:
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    except OverflowError:
        return False


def valid_id(value):
    try:
        return str(uuid.UUID(value)) == str(value).lower()
    except (ValueError, TypeError, AttributeError):
        return False


def clean_binding(binding, custom=False):
    if not isinstance(binding, dict) or not isinstance(binding.get("action"), str) or binding["action"] not in ACTIONS:
        raise ValueError("Choose a supported action")
    if not custom and (not isinstance(binding.get("gesture"), str) or binding["gesture"] not in GESTURES):
        raise ValueError("Choose a supported movement")
    if not isinstance(binding.get("enabled", True), bool):
        raise ValueError("Invalid enabled value")
    result = {"action": binding["action"], "enabled": binding.get("enabled", True)}
    if not custom:
        result["gesture"] = binding["gesture"]
    for field in ("targetID", "homeID", "targetName", "shortcutName"):
        value = binding.get(field, "")
        if not isinstance(value, str) or len(value) > 256 or any(ord(c) < 32 for c in value):
            raise ValueError("Invalid mapping details")
        result[field] = value
    return result


class MotionStudio:
    """Thread safe; raw sample storage is independent of browser rendering."""
    def __init__(self, data_dir=None, clock=time.time):
        self.clock = clock
        self.lock = threading.RLock()
        self.data_dir = Path(data_dir) if data_dir is not None else None
        self.movements = []
        self.recordings = []
        self.load_error = None
        self.stream_enabled = False
        self.browser_seen = 0
        self.phone_seen = None
        self.last_sample_at = None
        self.samples = deque(maxlen=1500)
        self.cursor = 0
        self.session_id = None
        self.batch_sequence = -1
        self.last_sensor_time = None
        self.closed_sessions = deque(maxlen=32)
        self.batch_gaps = 0
        self.sample_gaps = 0
        self.dropped_samples = 0
        self.active_recording = None
        self.configuration = None
        self.pending_mapping = None
        self.mapping_status = "Waiting for iPhone settings"
        self.metadata = {}
        self.watch_recording = False
        self.last_batch_recording = False
        self._load()

    def _load(self):
        if self.data_dir is None or not (self.data_dir / "library.json").exists():
            return
        try:
            data = json.loads((self.data_dir / "library.json").read_text(encoding="utf-8"))
            if data.get("schema") != 1 or not isinstance(data.get("movements"), list):
                raise ValueError("Invalid library")
            if any(not valid_id(item.get("id")) for item in data["movements"]):
                raise ValueError("Invalid movement IDs")
            self.movements = data["movements"]
            self.recordings = data.get("recordings", [])
            if not isinstance(self.recordings, list) or any(not valid_id(item.get("id")) for item in self.recordings):
                raise ValueError("Invalid recordings")
        except (ValueError, OSError, TypeError, AttributeError):
            self.load_error = "The saved movement library could not be read. Existing files were preserved."
            self.movements = []
            self.recordings = []

    def _write_json(self, name, data):
        if self.data_dir is None:
            return
        self.data_dir.mkdir(parents=True, exist_ok=True)
        target = self.data_dir / name
        temporary = target.with_suffix(".tmp")
        temporary.write_text(json.dumps(data, ensure_ascii=False, allow_nan=False, separators=(",", ":")), encoding="utf-8")
        temporary.replace(target)

    def _save_library(self):
        if self.load_error:
            raise ValueError(self.load_error)
        self._write_json("library.json", {"schema": 1, "movements": self.movements, "recordings": self.recordings})

    def _requested(self):
        return self.active_recording is not None or (self.stream_enabled and self.clock() - self.browser_seen <= 5)

    def _tick(self):
        if self.active_recording and self.clock() - self.active_recording["startedAt"] >= 60:
            self._finish_recording("60-second recording limit")
        if self.pending_mapping and self.clock() - self.pending_mapping["createdAt"] > 60:
            self.pending_mapping = None
            self.mapping_status = "Mapping edit expired; reconnect the iPhone and save again"

    def poll(self, payload):
        with self.lock:
            self._tick()
            if not isinstance(payload, dict) or not finite(payload.get("createdAt")):
                return 400, {"error": "Expected studio poll timestamp"}
            if abs(self.clock() - payload["createdAt"]) > 5:
                # Only reachable after server.py authenticates the bearer.
                # Expose time for a fresh later poll; this expired request must
                # not update configuration or acknowledge pending mapping edits.
                return 408, {"error": "Expired studio poll", "serverTime": self.clock()}
            configuration = payload.get("configuration")
            if configuration is not None:
                try:
                    clean = self._clean_configuration(configuration)
                except ValueError as error:
                    return 400, {"error": str(error)}
                if self.configuration is None:
                    self.mapping_status = "Settings received from iPhone"
                self.configuration = clean
            if self.pending_mapping and str(payload.get("appliedMappingEditID", "")).lower() == self.pending_mapping["id"]:
                self.mapping_status = ("Applied on iPhone; syncing Watch" if not payload.get("mappingError")
                                       else "Not applied; settings changed or iPhone rejected the edit. Refresh and save again.")
                self.pending_mapping = None
            self.phone_seen = self.clock()
            self.watch_recording = payload.get("watchRecording") is True
            response = {"ok": True, "studioProtocol": 1, "telemetryRequested": self._requested(),
                        "recording": self.active_recording is not None, "serverTime": self.clock()}
            if self.pending_mapping:
                response["pendingMappingEdit"] = copy.deepcopy(self.pending_mapping)
            return 200, response

    @staticmethod
    def _clean_configuration(configuration):
        if not isinstance(configuration, dict):
            raise ValueError("Invalid settings")
        revision = configuration.get("revision")
        profiles = configuration.get("profiles")
        if not isinstance(revision, str) or not 1 <= len(revision) <= 128 or not isinstance(profiles, list) or not 1 <= len(profiles) <= 10:
            raise ValueError("Invalid settings revision or profiles")
        result = {"revision": revision, "selectedProfileID": configuration.get("selectedProfileID"), "profiles": []}
        for profile in profiles:
            if not isinstance(profile, dict) or not isinstance(profile.get("id"), str) or not 1 <= len(profile["id"]) <= 128:
                raise ValueError("Invalid profile")
            if not isinstance(profile.get("name"), str) or len(profile["name"]) > 128:
                raise ValueError("Invalid profile name")
            bindings = profile.get("bindings")
            if not isinstance(bindings, list) or len(bindings) > 5:
                raise ValueError("Invalid profile bindings")
            clean = [clean_binding(binding) for binding in bindings]
            if len({binding["gesture"] for binding in clean}) != len(clean):
                raise ValueError("Duplicate binding")
            result["profiles"].append({"id": profile["id"], "name": profile["name"], "bindings": clean})
        if result["selectedProfileID"] not in [profile["id"] for profile in result["profiles"]]:
            raise ValueError("Invalid selected profile")
        return result

    def ingest(self, payload):
        with self.lock:
            self._tick()
            if (not isinstance(payload, dict) or type(payload.get("schema")) is not int or
                    payload["schema"] != 1 or not valid_id(payload.get("sessionID"))):
                return 400, {"error": "Invalid telemetry session"}
            if not finite(payload.get("createdAt")) or abs(self.clock() - payload["createdAt"]) > 5:
                return 408, {"error": "Expired telemetry batch"}
            sequence = payload.get("batchSequence")
            dropped = payload.get("droppedSamples", 0)
            recording_batch = payload.get("recording", False)
            if not isinstance(recording_batch, bool):
                return 400, {"error": "Invalid recording status"}
            if type(sequence) is not int or sequence < 0 or type(dropped) is not int or not 0 <= dropped <= 1000000:
                return 400, {"error": "Invalid telemetry sequence or dropped count"}
            frames = payload.get("samples")
            if not isinstance(frames, list) or not 1 <= len(frames) <= 200:
                return 400, {"error": "Expected 1-200 motion samples"}
            clean = []
            previous_time = None
            for frame in frames:
                if (not isinstance(frame, dict) or not finite(frame.get("time")) or not finite(frame.get("wallTime")) or
                        any(not finite(frame.get(key)) for key in CHANNELS)):
                    return 400, {"error": "Invalid motion sample"}
                if previous_time is not None and frame["time"] <= previous_time:
                    return 409, {"error": "Unordered motion samples"}
                previous_time = frame["time"]
                state = frame.get("state", "")
                if not isinstance(state, str) or len(state) > 256:
                    return 400, {"error": "Invalid motion state"}
                item = {key: frame[key] for key in ("time", "wallTime", *CHANNELS)}
                item["state"] = state
                for key in OPTIONAL_CHANNELS:
                    if key in frame and frame[key] is not None:
                        if not finite(frame[key]):
                            return 400, {"error": "Invalid optional motion channel"}
                        item[key] = frame[key]
                clean.append(item)
            session = payload["sessionID"].lower()
            if session in self.closed_sessions:
                return 409, {"error": "Closed telemetry session"}
            if self.session_id == session:
                if sequence <= self.batch_sequence or (self.last_sensor_time is not None and clean[0]["time"] <= self.last_sensor_time):
                    return 409, {"error": "Duplicate or reordered telemetry"}
            metadata = payload.get("metadata", {})
            if not isinstance(metadata, dict):
                return 400, {"error": "Invalid telemetry metadata"}
            safe_metadata = {}
            for key in ("watchModel", "watchOS", "referenceFrame", "appVersion", "requestedSampleHz"):
                value = metadata.get(key)
                if isinstance(value, str) and len(value) <= 128 or finite(value):
                    safe_metadata[key] = value
            if not self._requested():
                return 409, {"error": "Motion streaming is not requested"}
            if session != self.session_id:
                if self.session_id:
                    self.closed_sessions.append(self.session_id)
                    if self.active_recording:
                        if self.active_recording["ready"]:
                            self.active_recording["issues"].add("sensor session changed")
                        else:
                            # The Watch deliberately starts a fresh sensor
                            # session when it confirms capture-only mode.
                            self.active_recording["sessionID"] = session
                            self.active_recording["metadata"] = dict(safe_metadata)
                self.session_id = session
                self.batch_sequence = -1
                self.last_sensor_time = None
                self.metadata = safe_metadata
            batch_gaps = max(0, sequence - self.batch_sequence - 1)
            self.batch_gaps += batch_gaps
            self.dropped_samples += dropped
            if self.active_recording:
                self.active_recording["batchGaps"] += batch_gaps
                self.active_recording["droppedSamples"] += dropped
                if recording_batch:
                    self.active_recording["ready"] = True
                elif self.active_recording["ready"]:
                    self.active_recording["issues"].add("Watch recording mode interrupted")
            for item in clean:
                if self.last_sensor_time is not None and item["time"] - self.last_sensor_time > .04:
                    self.sample_gaps += 1
                    if self.active_recording:
                        self.active_recording["sampleGaps"] += 1
                self.last_sensor_time = item["time"]
                self.cursor += 1
                item["cursor"] = self.cursor
                self.samples.append(item)
                if self.active_recording and recording_batch:
                    if len(self.active_recording["samples"]) < 12000:
                        self.active_recording["samples"].append(dict(item))
                    else:
                        self.active_recording["issues"].add("sample buffer limit reached")
                        self._finish_recording("sample buffer limit")
            self.batch_sequence = sequence
            self.last_sample_at = self.clock()
            self.last_batch_recording = recording_batch
            return 200, {"ok": True, "accepted": len(clean), "cursor": self.cursor}

    def snapshot(self, after=0, browser=False):
        with self.lock:
            self._tick()
            if browser:
                self.browser_seen = self.clock()
            now = self.clock()
            active = self.active_recording
            return {"schema": 1, "serverTime": now, "streamEnabled": self.stream_enabled,
                    "telemetryRequested": self._requested(), "phoneConnected": self.phone_seen is not None and now - self.phone_seen < 4,
                    "lastSampleAt": self.last_sample_at, "stale": self.last_sample_at is None or now - self.last_sample_at > 1,
                    "cursor": self.cursor, "samples": [dict(s) for s in self.samples if s["cursor"] > after],
                    "batchGaps": self.batch_gaps, "sampleGaps": self.sample_gaps, "droppedSamples": self.dropped_samples,
                    "metadata": dict(self.metadata), "movements": copy.deepcopy(self.movements),
                    "recordings": copy.deepcopy(self.recordings), "configuration": copy.deepcopy(self.configuration),
                    "mappingStatus": self.mapping_status, "mappingPending": self.pending_mapping is not None,
                    "captureSettling": self.last_batch_recording and active is None,
                    "actions": ACTIONS, "gestures": GESTURES, "loadError": self.load_error,
                    "profileActions": {profile: sorted(actions) for profile, actions in PROFILE_ACTIONS.items()},
                    "activeRecording": None if active is None else {
                        "id": active["id"], "movementID": active["movementID"], "startedAt": active["startedAt"],
                        "ready": active["ready"], "sampleCount": len(active["samples"]),
                        "secondsRemaining": max(0, 60 - (now-active["startedAt"]))}}

    def control(self, operation, payload):
        with self.lock:
            self._tick()
            try:
                if operation == "stream/start":
                    self.stream_enabled = True
                    self.browser_seen = self.clock()
                elif operation == "stream/stop":
                    if self.active_recording:
                        raise ValueError("Save or cancel the recording before stopping the stream")
                    self.stream_enabled = False
                elif operation == "movements/create":
                    if self.load_error:
                        raise ValueError(self.load_error)
                    name = payload.get("name", "")
                    if not isinstance(name, str) or not 1 <= len(name.strip()) <= 80 or any(ord(c) < 32 for c in name):
                        raise ValueError("Use a movement name between 1 and 80 characters")
                    if len(self.movements) >= 250:
                        raise ValueError("Movement library limit reached (250)")
                    if any(m["name"].casefold() == name.strip().casefold() for m in self.movements):
                        raise ValueError("A movement with that name already exists")
                    movement = {"id": str(uuid.uuid4()), "name": name.strip(), "createdAt": self.clock(),
                                "mapping": None, "recognitionStatus": "untrained"}
                    self.movements.append(movement)
                    try:
                        self._save_library()
                    except Exception:
                        self.movements.pop()
                        raise
                    return 200, {"ok": True, "movement": copy.deepcopy(movement)}
                elif operation == "recordings/start":
                    if self.load_error:
                        raise ValueError(self.load_error)
                    movement = next((m for m in self.movements if m["id"] == payload.get("movementID")), None)
                    if movement is None:
                        raise ValueError("Choose a saved movement")
                    if self.active_recording:
                        raise ValueError("A recording is already running")
                    if self.last_sample_at is None or self.clock() - self.last_sample_at > 1 or not self._requested():
                        raise ValueError("Start the sensor stream and wait for fresh Watch samples before recording")
                    if self.last_batch_recording:
                        raise ValueError("Wait for the Watch to finish its previous recording before starting another")
                    if len(self.recordings) >= 5000:
                        raise ValueError("Recording library limit reached (5000)")
                    self.active_recording = {"id": str(uuid.uuid4()), "movementID": movement["id"],
                                             "movementName": movement["name"], "startedAt": self.clock(),
                                             "sessionID": self.session_id, "metadata": dict(self.metadata),
                                             "batchGaps": 0, "sampleGaps": 0, "droppedSamples": 0,
                                             "issues": set(), "samples": [], "ready": False}
                elif operation == "recordings/stop":
                    if not self.active_recording:
                        raise ValueError("No recording is running")
                    return 200, {"ok": True, "recording": self._finish_recording("saved manually")}
                elif operation == "recordings/cancel":
                    if not self.active_recording:
                        raise ValueError("No recording is running")
                    self.active_recording = None
                elif operation == "mappings/custom":
                    movement = next((m for m in self.movements if m["id"] == payload.get("movementID")), None)
                    if movement is None:
                        raise ValueError("Choose a saved movement")
                    binding = clean_binding(payload.get("binding"), custom=True)
                    binding["enabled"] = False  # No trained model exists yet.
                    original = movement["mapping"]
                    movement["mapping"] = binding
                    try:
                        self._save_library()
                    except Exception:
                        movement["mapping"] = original
                        raise
                elif operation == "mappings/builtin":
                    if self.configuration is None or self.phone_seen is None or self.clock() - self.phone_seen >= 4:
                        raise ValueError("Keep the paired iPhone open and wait for its settings")
                    if payload.get("revision") != self.configuration["revision"]:
                        return 409, {"error": "Settings changed; refresh this page and try again"}
                    if self.pending_mapping:
                        return 409, {"error": "Wait for the previous mapping edit to finish"}
                    profile = next((p for p in self.configuration["profiles"] if p["id"] == payload.get("profileID")), None)
                    if profile is None or profile["id"] not in ("computer", "phone"):
                        raise ValueError("Choose the Computer or Phone profile; edit Home targets on iPhone")
                    binding = clean_binding(payload.get("binding"))
                    if binding["action"] not in PROFILE_ACTIONS[profile["id"]]:
                        raise ValueError("Choose an action for this profile's target")
                    if binding["action"] == "shortcut" and not 1 <= len(binding["shortcutName"].strip()) <= 200:
                        raise ValueError("Enter an exact Shortcut name between 1 and 200 characters")
                    if any(binding[field] for field in ("targetID", "homeID", "targetName")):
                        raise ValueError("Edit Home targets on iPhone")
                    if binding["gesture"] not in [b["gesture"] for b in profile["bindings"]]:
                        raise ValueError("Choose an existing movement mapping")
                    bindings = [binding if b["gesture"] == binding["gesture"] else b for b in profile["bindings"]]
                    self.pending_mapping = {"id": str(uuid.uuid4()), "revision": self.configuration["revision"],
                                            "profileID": profile["id"], "bindings": copy.deepcopy(bindings),
                                            "createdAt": self.clock()}
                    self.mapping_status = "Waiting for iPhone to apply the mapping"
                else:
                    return 404, {"error": "Unknown studio operation"}
                return 200, {"ok": True}
            except ValueError as error:
                return 400, {"error": str(error)}
            except OSError:
                return 503, {"error": "Could not save the local movement library; check storage permissions and free space"}

    def _finish_recording(self, reason):
        recording = self.active_recording
        if recording is None:
            return None
        now = self.clock()
        samples = recording["samples"]
        issues = set(recording["issues"])
        if not samples:
            issues.add("no samples received")
        if not recording["ready"]:
            issues.add("Watch never confirmed recording mode")
        if samples and any(any(key not in sample for key in ("rawAx", "rawAy", "rawAz", "qx", "qy", "qz", "qw")) for sample in samples):
            issues.add("some raw acceleration or quaternion channels unavailable")
        if self.last_sample_at is None or now - self.last_sample_at > 1:
            issues.add("stream stale at stop")
        if recording["batchGaps"]:
            issues.add("missing telemetry batches")
        if recording["sampleGaps"]:
            issues.add("sample gaps over 40 ms")
        if recording["droppedSamples"]:
            issues.add("sender reported dropped samples")
        duration = samples[-1]["time"] - samples[0]["time"] if len(samples) > 1 else 0
        summary = {key: recording[key] for key in ("id", "movementID", "movementName", "startedAt", "sessionID", "metadata", "batchGaps", "sampleGaps", "droppedSamples")}
        summary.update({"stoppedAt": now, "duration": max(0, duration), "sampleCount": len(samples),
                        "measuredHz": (len(samples)-1)/duration if duration > 0 else 0,
                        "partial": bool(issues), "issues": sorted(issues), "stopReason": reason})
        self._write_json(summary["id"] + ".json", {"schema": 1, **summary, "samples": samples})
        self.recordings.append(summary)
        try:
            self._save_library()
        except Exception:
            self.recordings.pop()
            raise
        self.active_recording = None
        return copy.deepcopy(summary)

    def recording(self, recording_id):
        with self.lock:
            if not valid_id(recording_id) or not any(r["id"] == recording_id for r in self.recordings) or self.data_dir is None:
                return None
            try:
                return (self.data_dir / (recording_id + ".json")).read_bytes()
            except OSError:
                return None
