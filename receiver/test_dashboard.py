import json
import threading
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import uuid

from dashboard import dashboard_handler, start_dashboard
from http.server import ThreadingHTTPServer
from server import CommandProcessor


class DashboardTests(unittest.TestCase):
    def setUp(self):
        self.now = 100.0
        self.processor = CommandProcessor("private-test-token", clock=lambda: self.now)
        self.auth = "Bearer private-test-token"
        self.session = str(uuid.uuid4())
        self.sequence = 0

    def volume(self, operation, target=None, authorization=None):
        payload = {"id": str(uuid.uuid4()), "sessionID": self.session,
                   "revision": "test", "operation": operation,
                   "sequence": self.sequence, "createdAt": self.now}
        if target is not None:
            payload["target"] = target
        result = self.processor.handle_volume(authorization or self.auth, payload)
        self.sequence += 1
        self.now += .1
        return result

    def test_confirmed_volume_history_and_final_lock(self):
        self.assertEqual(self.processor.dashboard.snapshot()["phase"], "waiting")
        self.assertEqual(self.volume("begin")[0], 200)
        self.assertEqual(self.volume("update", .7)[0], 200)
        state = self.processor.dashboard.snapshot()
        self.assertEqual((state["phase"], state["volume"], state["anchor"]), ("live", .7, .5))
        self.assertFalse(state["execute"])
        self.assertEqual(self.volume("end", .65)[0], 200)
        state = self.processor.dashboard.snapshot()
        self.assertEqual((state["phase"], state["volume"]), ("locked", .65))
        self.assertEqual(state["history"][-1]["volume"], .65)
        self.assertEqual(self.volume("update", .9)[0], 409)
        self.assertEqual(self.processor.dashboard.snapshot()["volume"], .65)

    def test_timeout_and_audio_failure_do_not_claim_lock(self):
        self.volume("begin")
        self.now += 7
        self.assertEqual(self.processor.dashboard.snapshot()["phase"], "interrupted")
        self.assertIsNotNone(self.processor.live_volume.active)  # Display reads never alter protocol state.
        self.volume("update", .7)
        self.assertEqual(self.processor.dashboard.snapshot()["phase"], "interrupted")
        self.session = str(uuid.uuid4())
        self.sequence = 0
        self.volume("begin")
        self.processor.live_volume.execute = True
        with patch.object(self.processor.live_volume.audio, "set", side_effect=RuntimeError("device failed")):
            self.assertEqual(self.volume("end", .8)[0], 503)
        self.assertEqual(self.processor.dashboard.snapshot()["phase"], "interrupted")

    def test_unauthorized_and_expired_requests_do_not_publish_values(self):
        self.volume("begin", authorization="Bearer wrong-private-token")
        state = self.processor.dashboard.snapshot()
        self.assertIsNone(state["lastContact"])
        self.assertEqual(state["events"], [])
        self.sequence = 0
        self.volume("begin")
        self.now += 2
        payload = {"id": str(uuid.uuid4()), "sessionID": self.session, "revision": "test",
                   "operation": "update", "sequence": 1, "createdAt": self.now - 2, "target": .9}
        self.assertEqual(self.processor.handle_volume(self.auth, payload)[0], 408)
        self.assertEqual(self.processor.dashboard.snapshot()["volume"], .5)
        self.assertNotIn("private-token", json.dumps(self.processor.dashboard.snapshot()))

    def test_bounded_history_and_read_only_http_access(self):
        state = self.processor.dashboard
        for i in range(500):
            self.now += .2
            state.live_volume("update", 200, {"volume": .6}, True)
            state.command("next_track", False)
        self.assertLessEqual(len(state.snapshot()["history"]), 320)
        self.assertEqual(len(state.snapshot()["events"]), 24)
        server = ThreadingHTTPServer(("127.0.0.1", 0), dashboard_handler(state))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{server.server_port}"
        try:
            with urlopen(url + "/status", timeout=2) as response:
                self.assertEqual(response.headers["Cache-Control"], "no-store")
                raw = response.read().decode()
                self.assertEqual(json.loads(raw)["accepted"], 1000)
                self.assertNotIn(self.processor.token, raw)
            for path in ("/", "/dashboard.css", "/dashboard.js"):
                with urlopen(url + path, timeout=2) as response:
                    self.assertTrue(response.read())
            for headers in ({"Host": "foreign.example"}, {"Origin": "https://foreign.example"},
                            {"Sec-Fetch-Site": "cross-site"}):
                with self.assertRaises(HTTPError) as rejection:
                    urlopen(Request(url + "/status", headers=headers), timeout=2)
                self.assertEqual(rejection.exception.code, 403)
            with self.assertRaises(HTTPError) as missing:
                urlopen(url + "/../server.py", timeout=2)
            self.assertEqual(missing.exception.code, 404)
            with self.assertRaises(HTTPError) as post:
                urlopen(Request(url + "/status", data=b"{}"), timeout=2)
            self.assertEqual(post.exception.code, 403)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_browser_launch_failure_keeps_display_available(self):
        with patch("dashboard.webbrowser.open", side_effect=OSError("no browser")):
            server = start_dashboard(self.processor.dashboard)
        try:
            with urlopen(f"http://127.0.0.1:{server.server_port}/status", timeout=2) as response:
                self.assertEqual(response.status, 200)
        finally:
            server.shutdown()
            server.server_close()

    def test_console_only_launch_skips_dashboard(self):
        # Exercise main without binding a real command receiver or launching a browser.
        from server import main
        with patch("sys.argv", ["server.py", "--no-ui"]), \
                patch.dict("os.environ", {"WIZARDRY_TOKEN": "private-test-token"}), \
                patch("server.HTTPServer") as server, patch("server.start_dashboard") as display:
            server.return_value.serve_forever.side_effect = KeyboardInterrupt
            main()
            display.assert_not_called()
            server.return_value.server_close.assert_called_once()

    def test_default_launch_starts_and_closes_display(self):
        from server import main
        with patch("sys.argv", ["server.py"]), \
                patch.dict("os.environ", {"WIZARDRY_TOKEN": "private-test-token"}), \
                patch("server.HTTPServer") as server, patch("server.start_dashboard") as display:
            server.return_value.serve_forever.side_effect = KeyboardInterrupt
            main()
            display.assert_called_once()
            self.assertFalse(display.call_args.args[0].execute)
            display.return_value.shutdown.assert_called_once()
            display.return_value.server_close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
