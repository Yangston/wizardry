import copy
import json
from pathlib import Path
import tempfile
import threading
import unittest
from http.server import HTTPServer, ThreadingHTTPServer
from http.client import HTTPConnection
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import uuid

from dashboard import dashboard_handler
from server import CommandProcessor, handler_for
from studio import MotionStudio


class StudioTests(unittest.TestCase):
    def setUp(self):
        self.now = 100.0
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.studio = MotionStudio(self.directory.name, clock=lambda: self.now)
        self.session = str(uuid.uuid4())
        self.sequence = 0
        self.sample_time = 10.0
        self.configuration = {"revision": "r1", "selectedProfileID": "computer", "profiles": [
            {"id": "computer", "name": "Computer", "bindings": [{"gesture": "rollPositive", "action": "volumeUp", "enabled": True}]},
            {"id": "phone", "name": "Phone", "bindings": [{"gesture": "rollPositive", "action": "shortcut", "shortcutName": "Example", "enabled": True}]}]}

    def poll(self, **extra):
        return self.studio.poll({"operation": "poll", "createdAt": self.now, "configuration": self.configuration, **extra})

    def batch(self, count=10, recording=False):
        frames = []
        for _ in range(count):
            frame = {"time": self.sample_time, "wallTime": self.now, "ax": .1, "ay": .2, "az": .3,
                     "rx": .1, "ry": .2, "rz": .3, "gx": 0, "gy": -1, "gz": 0,
                     "roll": .2, "pitch": .3, "yaw": .4,
                     "rawAx": .1, "rawAy": -.8, "rawAz": .3, "rawTime": self.sample_time,
                     "qx": 0, "qy": 0, "qz": 0, "qw": 1, "mx": 10, "my": 20, "mz": 30, "magneticAccuracy": 2}
            frames.append(frame)
            self.sample_time += .01
        payload = {"schema": 1, "sessionID": self.session, "batchSequence": self.sequence, "createdAt": self.now,
                   "samples": frames, "droppedSamples": 0, "recording": recording,
                   "metadata": {"watchModel": "test watch", "requestedSampleHz": 100, "pairingToken": "never retain"}}
        self.sequence += 1
        return payload

    def start_recording(self):
        self.studio.control("stream/start", {})
        self.assertEqual(self.studio.ingest(self.batch())[0], 200)
        status, result = self.studio.control("movements/create", {"name": "Turn a page"})
        self.assertEqual(status, 200)
        self.movement_id = result["movement"]["id"]
        self.assertEqual(self.studio.control("recordings/start", {"movementID": self.movement_id})[0], 200)

    def test_recording_handshake_and_full_rate_persistence(self):
        self.start_recording()
        self.assertTrue(self.poll()[1]["recording"])
        self.assertFalse(self.studio.snapshot()["activeRecording"]["ready"])
        self.studio.ingest(self.batch(recording=False))
        self.assertEqual(self.studio.snapshot()["activeRecording"]["sampleCount"], 0)
        first = self.batch(200, recording=True)
        self.assertEqual(self.studio.ingest(first)[0], 200)
        self.studio.ingest(self.batch(200, recording=True))
        status, result = self.studio.control("recordings/stop", {})
        self.assertEqual(status, 200)
        saved = result["recording"]
        self.assertEqual(saved["sampleCount"], 400)
        self.assertFalse(saved["partial"])
        self.assertAlmostEqual(saved["measuredHz"], 100)
        exported = json.loads(self.studio.recording(saved["id"]))
        self.assertEqual(exported["samples"][0]["rawAx"], first["samples"][0]["rawAx"])
        self.assertEqual(exported["samples"][0]["time"], first["samples"][0]["time"])
        self.assertEqual(exported["samples"][0]["qw"], 1)
        self.assertNotIn("pairingToken", json.dumps(exported))
        self.assertTrue(self.studio.snapshot()["captureSettling"])
        self.assertEqual(self.studio.control("recordings/start", {"movementID": self.movement_id})[0], 400)
        self.studio.ingest(self.batch(recording=False))
        self.assertFalse(self.studio.snapshot()["captureSettling"])
        restarted = MotionStudio(self.directory.name, clock=lambda: self.now)
        self.assertEqual(len(restarted.snapshot()["recordings"]), 1)
        self.assertEqual(restarted.snapshot()["movements"][0]["name"], "Turn a page")
        self.assertFalse(restarted.snapshot()["streamEnabled"])

    def test_recording_gaps_drops_and_interruption_are_partial(self):
        self.start_recording()
        self.studio.ingest(self.batch(recording=True))
        self.sequence += 2
        self.sample_time += .2
        packet = self.batch(recording=True)
        packet["droppedSamples"] = 4
        self.studio.ingest(packet)
        self.studio.ingest(self.batch(recording=False))
        self.now += 2
        result = self.studio.control("recordings/stop", {})[1]["recording"]
        self.assertTrue(result["partial"])
        self.assertEqual(result["sampleCount"], 20)
        self.assertEqual(result["batchGaps"], 2)
        self.assertEqual(result["droppedSamples"], 4)
        self.assertIn("sample gaps over 40 ms", result["issues"])
        self.assertIn("stream stale at stop", result["issues"])
        self.assertIn("Watch recording mode interrupted", result["issues"])

    def test_expected_watch_session_at_capture_start_is_not_a_restart(self):
        self.start_recording()
        self.session = str(uuid.uuid4()); self.sequence = 0
        self.studio.ingest(self.batch(recording=True))
        saved = self.studio.control("recordings/stop", {})[1]["recording"]
        self.assertFalse(saved["partial"])
        self.assertEqual(saved["sessionID"], self.session)
        self.assertEqual(saved["metadata"]["requestedSampleHz"], 100)
        self.studio.ingest(self.batch(recording=False))
        self.studio.control("recordings/start", {"movementID": self.movement_id})
        self.studio.ingest(self.batch(recording=True))
        self.session = str(uuid.uuid4()); self.sequence = 0
        self.studio.ingest(self.batch(recording=True))
        saved = self.studio.control("recordings/stop", {})[1]["recording"]
        self.assertTrue(saved["partial"])
        self.assertIn("sensor session changed", saved["issues"])

    def test_recording_limit_cancelling_and_empty_capture_are_explicit(self):
        self.start_recording()
        self.assertEqual(self.studio.control("stream/stop", {})[0], 400)
        self.assertEqual(self.studio.control("recordings/start", {"movementID": self.movement_id})[0], 400)
        self.now += 61
        state = self.studio.snapshot()
        self.assertIsNone(state["activeRecording"])
        self.assertEqual(state["recordings"][0]["stopReason"], "60-second recording limit")
        self.assertTrue(state["recordings"][0]["partial"])
        self.assertIn("Watch never confirmed recording mode", state["recordings"][0]["issues"])
        self.studio.control("stream/start", {})
        self.studio.ingest(self.batch())
        self.studio.control("recordings/start", {"movementID": self.movement_id})
        self.assertEqual(self.studio.control("recordings/cancel", {})[0], 200)
        self.assertEqual(len(self.studio.snapshot()["recordings"]), 1)

    def test_old_duplicate_reordered_and_malformed_batches_rejected_atomically(self):
        self.studio.control("stream/start", {})
        good = self.batch()
        self.assertEqual(self.studio.ingest(good)[0], 200)
        self.assertEqual(self.studio.ingest(good)[0], 409)
        old = self.batch(); old["createdAt"] -= 6
        self.assertEqual(self.studio.ingest(old)[0], 408)
        bad = self.batch(); bad["samples"][-1]["ax"] = float("nan")
        self.assertEqual(self.studio.ingest(bad)[0], 400)
        bad = self.batch(); bad["samples"][-1]["qw"] = float("inf")
        self.assertEqual(self.studio.ingest(bad)[0], 400)
        bad = self.batch(); bad["samples"][1]["time"] = bad["samples"][0]["time"]
        self.assertEqual(self.studio.ingest(bad)[0], 409)
        bad = self.batch(); bad["batchSequence"] = True
        self.assertEqual(self.studio.ingest(bad)[0], 400)
        bad = self.batch(); bad["recording"] = "yes"
        self.assertEqual(self.studio.ingest(bad)[0], 400)
        self.assertEqual(self.studio.snapshot()["cursor"], 10)

    def test_stream_is_explicit_bounded_and_session_replays_rejected(self):
        self.assertEqual(self.studio.ingest(self.batch())[0], 409)
        self.studio.control("stream/start", {})
        old_session = self.session
        first = self.batch()
        self.assertEqual(self.studio.ingest(first)[0], 200)
        self.session = str(uuid.uuid4()); self.sequence = 0
        self.assertEqual(self.studio.ingest(self.batch())[0], 200)
        replay = self.batch(); replay["sessionID"] = old_session
        self.assertEqual(self.studio.ingest(replay)[0], 409)
        for _ in range(10):
            self.studio.ingest(self.batch(200))
        self.assertEqual(len(self.studio.snapshot()["samples"]), 1500)
        self.assertEqual(len(self.studio.snapshot(after=self.studio.cursor-5)["samples"]), 5)
        self.now += 6
        self.assertFalse(self.poll()[1]["telemetryRequested"])
        self.studio.snapshot(browser=True)
        self.assertTrue(self.poll()[1]["telemetryRequested"])

    def test_recording_requires_fresh_stream_and_saved_movement(self):
        self.assertEqual(self.studio.control("recordings/start", {"movementID": str(uuid.uuid4())})[0], 400)
        result = self.studio.control("movements/create", {"name": "Knob"})[1]
        self.assertEqual(self.studio.control("recordings/start", {"movementID": result["movement"]["id"]})[0], 400)
        self.assertEqual(self.studio.control("movements/create", {"name": " knob "})[0], 400)
        self.assertEqual(self.studio.control("movements/create", {"name": ""})[0], 400)

    def test_mapping_revision_handshake_and_inactive_custom_mapping(self):
        self.poll()
        edit = {"revision": "r1", "profileID": "computer", "binding": {"gesture": "rollPositive", "action": "nextTrack", "enabled": True}}
        self.assertEqual(self.studio.control("mappings/builtin", {**edit, "revision": "stale"})[0], 409)
        self.assertEqual(self.studio.control("mappings/builtin", edit)[0], 200)
        pending = self.poll()[1]["pendingMappingEdit"]
        self.assertEqual(pending["bindings"][0]["action"], "nextTrack")
        self.assertEqual(self.studio.control("mappings/builtin", edit)[0], 409)
        self.configuration["revision"] = "r2"
        self.assertNotIn("pendingMappingEdit", self.poll(appliedMappingEditID=pending["id"].upper())[1])
        self.assertIn("Applied", self.studio.snapshot()["mappingStatus"])
        movement = self.studio.control("movements/create", {"name": "A custom twist"})[1]["movement"]
        self.assertEqual(self.studio.control("mappings/custom", {"movementID": movement["id"], "binding": {"action": "volumeUp", "enabled": True}})[0], 200)
        stored = MotionStudio(self.directory.name).snapshot()["movements"][0]
        self.assertFalse(stored["mapping"]["enabled"])
        self.assertEqual(stored["recognitionStatus"], "untrained")
        self.assertEqual(self.studio.control("mappings/custom", {"movementID": movement["id"], "binding": {"action": "run_shell"}})[0], 400)

    def test_mapping_expiry_rejection_and_configuration_sanitization(self):
        self.configuration["pairingToken"] = "must not appear"
        self.poll()
        self.assertNotIn("pairingToken", json.dumps(self.studio.snapshot()))
        edit = {"revision": "r1", "profileID": "computer", "binding": {"gesture": "rollPositive", "action": "nextTrack"}}
        self.studio.control("mappings/builtin", edit)
        pending = self.poll()[1]["pendingMappingEdit"]
        self.poll(appliedMappingEditID=pending["id"], mappingError="Revision changed")
        self.assertIn("Not applied", self.studio.snapshot()["mappingStatus"])
        self.studio.control("mappings/builtin", edit)
        self.now += 61
        self.assertNotIn("pendingMappingEdit", self.poll()[1])
        self.assertIn("expired", self.studio.snapshot()["mappingStatus"])
        malformed = copy.deepcopy(self.configuration)
        malformed["profiles"][0]["bindings"][0]["action"] = ["volumeUp"]
        self.assertEqual(self.studio.poll({"createdAt": self.now, "configuration": malformed})[0], 400)

    def test_expired_authenticated_poll_exposes_time_without_applying_settings(self):
        self.poll()
        edit = {"revision": "r1", "profileID": "computer", "binding": {"gesture": "rollPositive", "action": "nextTrack"}}
        self.studio.control("mappings/builtin", edit)
        pending = self.poll()[1]["pendingMappingEdit"]
        changed = copy.deepcopy(self.configuration)
        changed["revision"] = "must-not-apply"
        payload = {"createdAt": self.now - 6, "configuration": changed, "appliedMappingEditID": pending["id"]}
        processor = CommandProcessor("private-test-token", clock=lambda: self.now)
        processor.studio = self.studio
        status, rejected = processor.handle_studio("Bearer incorrect-token", payload)
        self.assertEqual(status, 401)
        self.assertNotIn("serverTime", rejected)
        status, rejected = processor.handle_studio("Bearer private-test-token", payload)
        self.assertEqual(status, 408)
        self.assertEqual(rejected["serverTime"], self.now)
        self.assertEqual(self.studio.snapshot()["configuration"]["revision"], "r1")
        self.assertEqual(self.poll()[1]["pendingMappingEdit"]["id"], pending["id"])

    def test_corrupt_library_preserved_and_path_traversal_not_allowed(self):
        path = Path(self.directory.name) / "library.json"
        path.write_text("not JSON", encoding="utf-8")
        broken = MotionStudio(self.directory.name)
        self.assertIsNotNone(broken.snapshot()["loadError"])
        self.assertEqual(broken.control("movements/create", {"name": "New"})[0], 400)
        self.assertEqual(path.read_text(), "not JSON")
        self.assertIsNone(self.studio.recording("../library"))


class StudioHTTPTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.processor = CommandProcessor("private-studio-token", data_dir=self.directory.name)

    def start(self, handler, threaded=True):
        server = (ThreadingHTTPServer if threaded else HTTPServer)(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(lambda: (server.shutdown(), server.server_close(), thread.join()))
        return f"http://127.0.0.1:{server.server_port}"

    def test_local_writes_require_origin_host_json_and_csrf_not_pairing_token(self):
        url = self.start(dashboard_handler(self.processor.dashboard))
        with urlopen(url + "/api/studio") as response:
            raw = response.read().decode(); state = json.loads(raw)
        self.assertNotIn(self.processor.token, raw)
        csrf = state["csrfToken"]
        data = json.dumps({"name": "New movement"}).encode()
        good_headers = {"Content-Type": "application/json", "X-Wizardry-CSRF": csrf, "Origin": url}
        for headers in ({}, {**good_headers, "X-Wizardry-CSRF": self.processor.token},
                        {**good_headers, "Origin": "https://attacker.example"}, {**good_headers, "Host": "attacker.example"},
                        {**good_headers, "Sec-Fetch-Site": "cross-site"}):
            with self.assertRaises(HTTPError) as rejected:
                urlopen(Request(url + "/api/movements/create", data=data, headers=headers))
            self.assertEqual(rejected.exception.code, 403)
        with urlopen(Request(url + "/api/movements/create", data=data, headers=good_headers)) as response:
            self.assertEqual(response.status, 200)
        for path in ("/studio", "/recordings", "/mappings", "/studio.js", "/studio.css"):
            with urlopen(url + path) as response:
                self.assertEqual(response.status, 200)
                self.assertEqual(response.headers["Cache-Control"], "no-store")

    def test_remote_endpoints_require_bearer_and_enforce_body_limit(self):
        url = self.start(handler_for(self.processor), threaded=False)
        import time
        payload = json.dumps({"operation": "poll", "createdAt": time.time()}).encode()
        for path in ("/studio", "/telemetry"):
            with self.assertRaises(HTTPError) as rejected:
                urlopen(Request(url + path, data=payload, headers={"Content-Type": "application/json"}))
            self.assertEqual(rejected.exception.code, 401)
        with urlopen(Request(url + "/studio", data=payload, headers={"Authorization": "Bearer private-studio-token"})) as response:
            reply = json.load(response)
            self.assertEqual(reply["studioProtocol"], 1)
            self.assertFalse(reply["telemetryRequested"])
            self.assertFalse(reply["recording"])
        connection = HTTPConnection(url.removeprefix("http://"), timeout=2)
        try:
            connection.putrequest("POST", "/telemetry")
            connection.putheader("Content-Length", "262145")
            connection.endheaders()
            self.assertEqual(connection.getresponse().status, 413)
        finally:
            connection.close()


if __name__ == "__main__":
    unittest.main()
