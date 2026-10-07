import json
import threading
import time
import unittest
import urllib.error
import urllib.request
import uuid
from http.server import HTTPServer
from live_volume import LiveVolumeProcessor
from server import CommandProcessor, handler_for


class FakeAudio:
    def __init__(self):
        self.value = 0.37
        self.device = "speakers"
        self.sets = []

    def read(self):
        return self.value, self.device

    def set(self, target, expected_device):
        if expected_device != self.device:
            raise RuntimeError("Default audio device changed")
        self.value = target
        self.sets.append(target)
        return target


class LiveVolumeTests(unittest.TestCase):
    def setUp(self):
        self.now = 100.0
        self.pacing_now = 10.0
        self.audio = FakeAudio()
        self.processor = LiveVolumeProcessor(True, lambda: self.now, self.audio,
                                             pacing_clock=lambda: self.pacing_now)
        self.session = str(uuid.uuid4())

    def advance(self, seconds):
        self.now += seconds
        self.pacing_now += seconds

    def request(self, operation="begin", sequence=0, target=None, **changes):
        value = {"id": str(uuid.uuid4()), "sessionID": self.session, "revision": "r1",
                 "sequence": sequence, "createdAt": self.now, "operation": operation}
        if target is not None:
            value["target"] = target
        value.update(changes)
        return value

    def test_begin_reads_actual_volume_and_updates_are_absolute(self):
        status, reply = self.processor.handle(self.request())
        self.assertEqual(status, 200)
        self.assertEqual(reply["volume"], 0.37)
        self.assertEqual(reply["transportVersion"], 2)
        self.assertEqual(self.audio.sets, [])
        self.assertEqual(self.processor.handle(self.request("update", 1, 0.6))[0], 200)
        self.now += 0.21
        self.assertEqual(self.processor.handle(self.request("update", 2, 0.2))[0], 200)
        self.assertEqual(self.audio.sets, [0.6, 0.2])

    def test_end_closes_session_and_old_updates_cannot_change_volume(self):
        self.processor.handle(self.request())
        update = self.request("update", 1, 0.8)
        self.processor.handle(update)
        status, reply = self.processor.handle(self.request("end", 2, 0.7))
        self.assertEqual(status, 200)
        self.assertEqual(reply["message"], "Locked")
        self.assertEqual(self.processor.handle(update)[0], 409)
        self.assertEqual(self.processor.handle(self.request("update", 3, 0.9))[0], 409)
        self.assertEqual(self.processor.handle(self.request())[0], 409)
        self.assertEqual(self.audio.value, 0.7)

    def test_expired_future_malformed_and_nonfinite_do_not_touch_audio(self):
        for patch in ({"createdAt": 98}, {"createdAt": 101}, {"sequence": True},
                      {"sequence": -1}, {"operation": []}, {"revision": ""},
                      {"sessionID": "bad"}, {"createdAt": float("nan")}, {"target": 0.5}):
            with self.subTest(patch=patch):
                self.assertIn(self.processor.handle(self.request(**patch))[0], (400, 408))
        self.processor.handle(self.request())
        for target in (-0.1, 1.1, float("nan"), float("inf"), True, "0.4"):
            self.assertEqual(self.processor.handle(self.request("update", 1, target))[0], 400)
        self.assertEqual(self.audio.sets, [])

    def test_order_revision_duplicate_do_not_consume_tokens(self):
        begin = self.request()
        self.processor.handle(begin)
        self.assertEqual(self.processor.handle(begin)[0], 409)
        self.assertEqual(self.processor.handle(self.request("update", 1, 0.5, revision="old"))[0], 409)
        update = self.request("update", 2, 0.5)
        self.assertEqual(self.processor.handle(update)[0], 200)
        self.assertEqual(self.processor.handle(update)[0], 409)
        self.assertEqual(self.processor.handle(self.request("update", 1, 0.6))[0], 409)
        for sequence in range(3, 6):
            self.assertEqual(self.processor.handle(self.request("update", sequence, 0.6))[0], 200)
        self.assertEqual(self.processor.handle(self.request("update", 6, 0.7))[0], 429)
        self.assertEqual(self.audio.sets, [0.5, 0.6, 0.6, 0.6])

    def test_twenty_hz_gradual_updates_start_at_live_volume_without_reset(self):
        self.audio.value = 0.73
        status, reply = self.processor.handle(self.request())
        self.assertEqual(status, 200)
        self.assertEqual(reply["volume"], 0.73)
        self.assertEqual(self.audio.sets, [])
        targets = [0.73 + step*0.001 for step in range(1, 21)]
        for sequence, target in enumerate(targets, 1):
            self.advance(0.05)
            self.assertEqual(self.processor.handle(self.request("update", sequence, target))[0], 200)
        self.assertEqual(self.audio.sets, targets)
        self.assertEqual(self.processor.handle(self.request("end", 21, targets[-1]))[0], 200)
        self.assertEqual(self.processor.handle(self.request("update", 22, 0.8))[0], 409)

    def test_fifty_hz_sustained_updates_preserve_every_ordered_target(self):
        self.processor.handle(self.request())
        targets = [0.2 + (step % 300)*0.001 for step in range(1, 501)]
        for sequence, target in enumerate(targets, 1):
            self.advance(0.02)
            self.assertEqual(self.processor.handle(self.request("update", sequence, target))[0], 200)
        self.assertEqual(self.audio.sets, targets)
        self.assertEqual(self.processor.active["sequence"], 500)

    def test_four_request_burst_is_bounded_and_end_bypasses_limiter(self):
        self.processor.handle(self.request())
        for sequence in range(1, 5):
            self.assertEqual(self.processor.handle(self.request("update", sequence, 0.5))[0], 200)
        self.assertEqual(self.processor.handle(self.request("update", 5, 0.9))[0], 429)
        self.assertEqual(self.processor.active["sequence"], 4)
        self.assertEqual(self.audio.sets, [0.5]*4)
        status, reply = self.processor.handle(self.request("end", 6, 0.4))
        self.assertEqual(status, 200)
        self.assertEqual(reply["volume"], 0.4)
        self.assertIsNone(self.processor.active)
        self.assertEqual(self.processor.handle(self.request("update", 7, 0.9))[0], 409)

    def test_tokens_refill_at_fifty_hz_and_never_exceed_four(self):
        self.processor.handle(self.request())
        for sequence in range(1, 5):
            self.processor.handle(self.request("update", sequence, 0.5))
        self.advance(0.019)
        self.assertEqual(self.processor.handle(self.request("update", 5, 0.6))[0], 429)
        self.advance(0.001)
        self.assertEqual(self.processor.handle(self.request("update", 6, 0.6))[0], 200)
        self.assertEqual(self.processor.handle(self.request("update", 7, 0.7))[0], 429)
        self.advance(1)
        for sequence in range(8, 12):
            self.assertEqual(self.processor.handle(self.request("update", sequence, 0.5))[0], 200)
        self.assertEqual(self.processor.handle(self.request("update", 12, 0.7))[0], 429)

    def test_wall_clock_changes_do_not_refill_pacing_and_expiry_stays_wall_based(self):
        self.processor.handle(self.request())
        for sequence in range(1, 5):
            self.processor.handle(self.request("update", sequence, 0.5))
        self.now += 3
        self.assertEqual(self.processor.handle(self.request("update", 5, 0.9))[0], 429)
        self.now -= 4
        self.assertEqual(self.processor.handle(self.request("update", 6, 0.9))[0], 429)
        self.pacing_now += 0.02
        self.assertEqual(self.processor.handle(self.request("update", 7, 0.6))[0], 200)
        self.pacing_now += 1
        self.assertEqual(self.processor.handle(self.request("update", 8, 0.9, createdAt=self.now-1.01))[0], 408)
        self.assertEqual(self.processor.handle(self.request("update", 9, 0.9, createdAt=self.now+0.11))[0], 408)
        self.assertEqual(self.audio.value, 0.6)

    def test_backward_pacing_clock_does_not_create_tokens(self):
        self.processor.handle(self.request())
        for sequence in range(1, 5):
            self.processor.handle(self.request("update", sequence, 0.5))
        self.pacing_now -= 1
        self.assertEqual(self.processor.handle(self.request("update", 5, 0.8))[0], 429)
        self.pacing_now += 1
        self.assertEqual(self.processor.handle(self.request("update", 6, 0.8))[0], 429)
        self.pacing_now += 0.02
        self.assertEqual(self.processor.handle(self.request("update", 7, 0.6))[0], 200)

    def test_idle_expiry_device_change_and_new_session_invalidate_old(self):
        self.processor.handle(self.request())
        self.now += 6.1
        self.assertEqual(self.processor.handle(self.request("update", 1, 0.5))[0], 409)
        self.session = str(uuid.uuid4())
        self.processor.handle(self.request())
        self.audio.device = "headphones"
        self.assertEqual(self.processor.handle(self.request("end", 1, 0.6))[0], 503)
        self.assertEqual(self.processor.handle(self.request("update", 2, 0.8))[0], 409)
        self.assertEqual(self.audio.sets, [])

    def test_new_begin_replaces_old_session(self):
        old = self.session
        self.processor.handle(self.request())
        self.session = str(uuid.uuid4())
        self.processor.handle(self.request())
        self.assertEqual(self.processor.handle(self.request("update", 1, 0.9, sessionID=old))[0], 409)

    def test_dry_run_never_calls_audio(self):
        self.processor.execute = False
        status, reply = self.processor.handle(self.request())
        self.assertEqual(reply["outcome"], "dryRun")
        self.assertEqual(self.processor.handle(self.request("end", 1, 0.7))[0], 200)
        self.assertEqual(self.audio.sets, [])
        self.assertEqual(self.audio.value, 0.37)

    def test_authenticated_clock_sample_supports_skew_but_not_stale_requests(self):
        server_clock = lambda: 102.0  # PC clock is two seconds ahead of phone
        processor = CommandProcessor("test-token-123456789",clock=server_clock)
        auth = "Bearer test-token-123456789"
        status, ping = processor.handle(auth,{"id":str(uuid.uuid4()),"command":"ping","timestamp":100.0})
        self.assertEqual(status,200)
        self.assertTrue(ping["liveVolume"])
        self.assertEqual(ping["liveVolumeProtocol"],2)
        self.assertEqual(ping["serverTime"],102.0)
        unaligned = self.request(createdAt=100.0)
        self.assertEqual(processor.handle_volume(auth,unaligned)[0],408)
        aligned = self.request(createdAt=100.0+(ping["serverTime"]-100.02))
        status,reply = processor.handle_volume(auth,aligned)
        self.assertEqual(status,200)
        self.assertEqual(reply["serverTime"],102.0)
        self.assertEqual(reply["volume"],0.5)
        self.assertEqual(reply["transportVersion"],2)
        stale = self.request(createdAt=100.5)  # still rejected against PC clock
        self.assertEqual(processor.handle_volume(auth,stale)[0],408)

    def test_real_http_auth_and_volume_round_trip(self):
        processor = CommandProcessor("test-token-123456789")
        server = HTTPServer(("127.0.0.1", 0), handler_for(processor))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def post(payload, auth):
            request = urllib.request.Request(f"http://127.0.0.1:{server.server_port}/volume",
                data=json.dumps(payload).encode(), headers={"Authorization": auth})
            return urllib.request.urlopen(request, timeout=2)
        try:
            event = self.request(createdAt=time.time())
            with self.assertRaises(urllib.error.HTTPError) as error:
                post(event, "wrong")
            self.assertEqual(error.exception.code, 401)
            with post(event, "Bearer test-token-123456789") as response:
                reply = json.load(response)
                self.assertEqual(reply["volume"], 0.5)
                self.assertEqual(reply["transportVersion"], 2)
            event = self.request("end", 1, 0.42, createdAt=time.time())
            with post(event, "Bearer test-token-123456789") as response:
                self.assertEqual(json.load(response)["volume"], 0.42)
        finally:
            server.shutdown(); server.server_close(); thread.join()


if __name__ == "__main__":
    unittest.main()
