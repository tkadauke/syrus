import os
import unittest
from unittest import mock

import gateway


class SessionProtocolTest(unittest.TestCase):
    def tearDown(self):
        with gateway.sessions_lock:
            remaining = list(gateway.sessions.values())
            gateway.sessions.clear()
        for session in remaining:
            session.cleanup()

    def test_appends_chunks_to_one_recording_in_order(self):
        session = gateway.Session({"content_type": "audio/webm"})
        self.addCleanup(session.cleanup)
        observed = []

        def decode(current):
            with open(current.path, "rb") as recording:
                observed.append(recording.read())
            return {"text": "hypothesis"}

        with mock.patch.object(gateway, "transcribe", side_effect=decode):
            session.append(1, b"header-and-audio")
            session.append(2, b"continuation")

        self.assertEqual(observed, [b"header-and-audio", b"header-and-audiocontinuation"])

    def test_rejects_out_of_order_chunks_without_mutating_audio(self):
        session = gateway.Session({})
        self.addCleanup(session.cleanup)
        with self.assertRaisesRegex(gateway.ProtocolError, "expected chunk 1"):
            session.append(2, b"late")
        self.assertFalse(os.path.exists(session.path))

    def test_take_session_releases_registry_ownership(self):
        session = gateway.Session({})
        self.addCleanup(session.cleanup)
        with gateway.sessions_lock:
            gateway.sessions[session.id] = session
        self.assertIs(gateway.take_session(session.id), session)
        with self.assertRaisesRegex(gateway.ProtocolError, "not found"):
            gateway.find_session(session.id)


if __name__ == "__main__":
    unittest.main()
