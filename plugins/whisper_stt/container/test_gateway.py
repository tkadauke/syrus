import os
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import gateway


class FakeDecoder:
    def __init__(self, _content_type):
        self.pcm = bytearray()
        self.feeds = []
        self.finished = False
        self.closed = False

    def feed(self, audio):
        self.feeds.append(audio)
        self.pcm.extend(b"\0\0" * gateway.SAMPLE_RATE)

    def wait_for_growth(self, _previous_size, timeout=1.0):
        return len(self.pcm)

    def snapshot(self, length=None):
        return bytes(self.pcm if length is None else self.pcm[:length])

    def discard(self, length):
        del self.pcm[:length]

    @property
    def size(self):
        return len(self.pcm)

    def finish(self):
        self.finished = True

    def close(self):
        self.closed = True


class SessionProtocolTest(unittest.TestCase):
    def setUp(self):
        self.decoder = FakeDecoder("audio/webm")
        self.session = gateway.Session(
            {"content_type": "audio/webm"}, decoder_factory=lambda _: self.decoder,
        )

    def tearDown(self):
        self.session.cleanup()
        with gateway.sessions_lock:
            remaining = list(gateway.sessions.values())
            gateway.sessions.clear()
        for session in remaining:
            session.cleanup()

    def test_feeds_ordered_chunks_to_one_stateful_decoder(self):
        with mock.patch.object(gateway, "transcribe_pcm", side_effect=["hello", "hello world"]):
            first = self.session.append(1, b"webm-header-and-cluster")
            second = self.session.append(2, b"continuation-cluster")

        self.assertEqual(self.decoder.feeds, [b"webm-header-and-cluster", b"continuation-cluster"])
        self.assertEqual(first, {"text": "hello"})
        self.assertEqual(second, {"text": "hello world"})

    def test_rejects_out_of_order_chunks_before_decoder(self):
        with self.assertRaisesRegex(gateway.ProtocolError, "expected chunk 1"):
            self.session.append(2, b"late")
        self.assertEqual(self.decoder.feeds, [])

    def test_real_decoder_rejects_non_streamable_batch_formats(self):
        with self.assertRaisesRegex(gateway.ProtocolError, "does not support streaming"):
            gateway.MediaDecoder("audio/mp4")

    def test_bounds_interim_inference_and_commits_old_audio_once(self):
        self.decoder.pcm.extend(b"\0" * (gateway.INTERIM_WINDOW_BYTES + 2))
        observed_sizes = []

        def transcribe(_session, pcm):
            observed_sizes.append(len(pcm))
            return "committed" if len(observed_sizes) == 1 else "interim"

        with mock.patch.object(gateway, "transcribe_pcm", side_effect=transcribe):
            result = self.session.hypothesis(final=False)
            revised = self.session.hypothesis(final=False)

        self.assertEqual(observed_sizes, [
            gateway.COMMIT_BYTES,
            gateway.INTERIM_WINDOW_BYTES - gateway.COMMIT_BYTES + 2,
            gateway.INTERIM_WINDOW_BYTES - gateway.COMMIT_BYTES + 2,
        ])
        self.assertLessEqual(self.decoder.size, gateway.INTERIM_WINDOW_BYTES)
        self.assertEqual(result, {"text": "committed interim"})
        self.assertEqual(revised, {"text": "committed interim"})
        self.assertEqual(self.session.committed_text, "committed")

    def test_finish_flushes_and_cleanup_closes_decoder(self):
        with mock.patch.object(gateway, "transcribe_pcm", return_value="final text"):
            self.session.append(1, b"audio")
            result = self.session.finish()
        self.session.cleanup()

        self.assertTrue(self.decoder.finished)
        self.assertTrue(self.decoder.closed)
        self.assertEqual(result, {"text": "final text"})

    @unittest.skipUnless(shutil.which("ffmpeg"), "ffmpeg is required")
    def test_real_decoder_accepts_fragmented_webm_through_one_process(self):
        with tempfile.TemporaryDirectory() as directory:
            media_path = os.path.join(directory, "sample.webm")
            subprocess.run([
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                "-i", "sine=frequency=440:duration=2", "-c:a", "libopus", media_path,
            ], check=True)
            with open(media_path, "rb") as media:
                encoded = media.read()

        decoder = gateway.MediaDecoder("audio/webm")
        try:
            boundaries = [len(encoded) // 7, len(encoded) // 2]
            previous_size = decoder.size
            decoder.feed(encoded[:boundaries[0]])
            decoder.wait_for_growth(previous_size)
            previous_size = decoder.size
            decoder.feed(encoded[boundaries[0]:boundaries[1]])
            decoder.wait_for_growth(previous_size)
            previous_size = decoder.size
            decoder.feed(encoded[boundaries[1]:])
            decoder.wait_for_growth(previous_size)
            self.assertGreater(decoder.size, 0, "decoder should emit PCM before end-of-stream")
            decoder.finish()
            self.assertGreater(decoder.size, gateway.PCM_BYTES_PER_SECOND)
        finally:
            decoder.close()

    def test_take_session_releases_registry_ownership(self):
        with gateway.sessions_lock:
            gateway.sessions[self.session.id] = self.session
        self.assertIs(gateway.take_session(self.session.id), self.session)
        with self.assertRaisesRegex(gateway.ProtocolError, "not found"):
            gateway.find_session(self.session.id)


if __name__ == "__main__":
    unittest.main()
