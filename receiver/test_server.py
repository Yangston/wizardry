import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import urllib.request
import uuid
from http.server import HTTPServer
from server import CommandProcessor, handler_for, KEY_CODES, pairing_token_file


class PairingTokenTests(unittest.TestCase):
    def test_restart_preserves_authenticated_pairing_in_dry_run_and_execute(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".pairing-token"
            token = pairing_token_file(path)
            self.assertGreaterEqual(len(token), 16)
            self.assertEqual(pairing_token_file(path), token)
            if platform.system() != "Windows":
                self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            for execute in (False, True):
                processor = CommandProcessor(pairing_token_file(path), execute=execute)
                ping = {"id": str(uuid.uuid4()), "command": "ping", "timestamp": time.time()}
                status, body = processor.handle("Bearer " + token, ping)
                self.assertEqual(status, 200)
                self.assertFalse(body["executed"])
                self.assertEqual(processor.handle("Bearer incorrect-token", ping)[0], 401)
                self.assertEqual(processor.handle_volume("Bearer incorrect-token", {})[0], 401)

    def test_invalid_existing_file_is_not_silently_rotated(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".pairing-token"
            path.write_text("invalid", encoding="ascii")
            with self.assertRaises(ValueError):
                pairing_token_file(path)
            self.assertEqual(path.read_text(encoding="ascii"), "invalid")

    def test_windows_permission_failure_does_not_leave_a_credential(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".pairing-token"
            identity = subprocess.CompletedProcess([], 0, stdout='"User","S-1-5-21-123"\n')
            def command(args, **kwargs):
                if args[0] == "whoami":
                    return identity
                self.assertEqual(path.read_bytes(), b"")
                raise subprocess.CalledProcessError(1, args)
            with patch("server.platform.system", return_value="Windows"), patch("server.subprocess.run", side_effect=command):
                with self.assertRaises(subprocess.CalledProcessError):
                    pairing_token_file(path)
            self.assertFalse(path.exists())


class ReceiverTests(unittest.TestCase):
    def setUp(self):
        self.actions = []
        self.processor = CommandProcessor("test-token-123456789", execute=True,
                                          clock=lambda: 100, volume_action=self.actions.append)

    def command(self, name="volume_up"):
        return {"id": str(uuid.uuid4()), "command": name, "timestamp": 100}

    def test_auth_expiry_allowlist_and_duplicate_do_not_execute(self):
        p = self.processor
        auth = "Bearer test-token-123456789"
        self.assertEqual(p.handle("wrong", self.command())[0], 401)
        expired = self.command()
        expired["timestamp"] = 0
        self.assertEqual(p.handle(auth, expired)[0], 408)
        self.assertEqual(p.handle(auth, self.command("run_shell"))[0], 400)
        command = self.command()
        self.assertEqual(p.handle(auth, command)[0], 200)
        self.assertEqual(p.handle(auth, command)[0], 409)
        self.assertEqual(p.handle(auth, self.command())[0], 429)
        self.assertEqual(self.actions, ["volume_up"])

    def test_media_and_presentation_commands_are_allowlisted(self):
        for command in KEY_CODES:
            with self.subTest(command=command):
                actions = []
                processor = CommandProcessor("test-token-123456789", execute=True,
                                             clock=lambda:100, volume_action=actions.append)
                self.assertEqual(processor.handle("Bearer test-token-123456789", self.command(command))[0], 200)
                self.assertEqual(actions, [command])

    def test_dry_run_and_ping_never_execute(self):
        self.processor.execute = False
        status, body = self.processor.handle("Bearer test-token-123456789", self.command())
        self.assertEqual(status, 200)
        self.assertFalse(body["executed"])
        self.assertEqual(self.actions, [])
        self.processor.execute = True
        status, body = self.processor.handle("Bearer test-token-123456789", self.command("ping"))
        self.assertEqual(status, 200)
        self.assertTrue(body["liveVolume"])
        self.assertEqual(body["liveVolumeProtocol"], 2)
        self.assertEqual(self.actions, [])

    def test_live_volume_capabilities_require_authenticated_ping(self):
        status, body = self.processor.handle("wrong", self.command("ping"))
        self.assertEqual(status, 401)
        self.assertNotIn("liveVolumeProtocol", body)
        self.assertNotIn("liveVolume", body)

    def test_unauthorized_volume_requests_do_not_consume_burst(self):
        processor = CommandProcessor("test-token-123456789", clock=lambda: 100,
                                     pacing_clock=lambda: 10)
        session_id = str(uuid.uuid4())
        def request(operation, sequence):
            payload = {"id": str(uuid.uuid4()), "sessionID": session_id,
                       "revision": "r1", "operation": operation,
                       "sequence": sequence, "createdAt": 100}
            if operation != "begin":
                payload["target"] = 0.5
            return payload
        auth = "Bearer test-token-123456789"
        self.assertEqual(processor.handle_volume(auth, request("begin", 0))[0], 200)
        for sequence in range(1, 5):
            self.assertEqual(processor.handle_volume("wrong", request("update", sequence))[0], 401)
        for sequence in range(1, 5):
            self.assertEqual(processor.handle_volume(auth, request("update", sequence))[0], 200)
        self.assertEqual(processor.handle_volume(auth, request("update", 5))[0], 429)

    def test_real_http_round_trip(self):
        processor = CommandProcessor("test-token-123456789")
        server = HTTPServer(("127.0.0.1", 0), handler_for(processor))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            command = self.command("ping")
            command["timestamp"] = time.time()
            request = urllib.request.Request(
                f"http://127.0.0.1:{server.server_port}/command", data=json.dumps(command).encode(),
                headers={"Authorization": "Bearer test-token-123456789", "Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=2) as response:
                self.assertEqual(response.status, 200)
                body = json.load(response)
                self.assertFalse(body["executed"])
                self.assertEqual(body["liveVolumeProtocol"], 2)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
