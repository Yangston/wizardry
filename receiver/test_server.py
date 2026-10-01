import json
import threading
import time
import unittest
import urllib.request
import uuid
from http.server import HTTPServer
from server import CommandProcessor, handler_for, KEY_CODES


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
        self.processor.handle("Bearer test-token-123456789", self.command("ping"))
        self.assertEqual(self.actions, [])

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
                self.assertFalse(json.load(response)["executed"])
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
