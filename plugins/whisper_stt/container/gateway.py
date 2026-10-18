#!/usr/bin/env python3
"""Session-oriented streaming gateway in front of whisper-server."""

import io
import json
import os
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "0.0.0.0"
PORT = int(os.environ.get("WHISPER_GATEWAY_PORT", "8080"))
UPSTREAM = os.environ.get("WHISPER_UPSTREAM_URL", "http://127.0.0.1:8081")
MAX_BYTES = 10 * 1024 * 1024
SESSION_TIMEOUT = 120
SAMPLE_RATE = 16_000
PCM_BYTES_PER_SECOND = SAMPLE_RATE * 2
INTERIM_WINDOW_BYTES = 15 * PCM_BYTES_PER_SECOND
COMMIT_BYTES = 10 * PCM_BYTES_PER_SECOND
MIN_TRANSCRIBE_BYTES = PCM_BYTES_PER_SECOND // 2
STREAM_FORMATS = {"audio/webm": "webm", "audio/ogg": "ogg"}


class ProtocolError(Exception):
    def __init__(self, status, message):
        self.status = status
        self.message = message


class MediaDecoder:
    """One persistent ffmpeg process that owns media-container state."""

    def __init__(self, content_type):
        input_format = STREAM_FORMATS.get(content_type)
        if not input_format:
            raise ProtocolError(415, "content type does not support streaming")
        self.process = subprocess.Popen(
            [
                "ffmpeg", "-hide_banner", "-loglevel", "error",
                "-f", input_format, "-i", "pipe:0", "-vn", "-ac", "1",
                "-ar", str(SAMPLE_RATE), "-f", "s16le", "pipe:1",
            ],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, bufsize=0,
        )
        self.pcm = bytearray()
        self.condition = threading.Condition()
        self.closed = False
        self.reader = threading.Thread(target=self._read_output, daemon=True)
        self.reader.start()

    def feed(self, audio):
        if self.closed or self.process.poll() is not None:
            raise ProtocolError(422, "audio decoder is not running")
        try:
            self.process.stdin.write(audio)
            self.process.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            raise ProtocolError(422, "audio decoder rejected the stream") from error

    def wait_for_growth(self, previous_size, timeout=1.0):
        with self.condition:
            self.condition.wait_for(
                lambda: len(self.pcm) > previous_size or self.process.poll() is not None,
                timeout=timeout,
            )
            return len(self.pcm)

    def snapshot(self, length=None):
        with self.condition:
            return bytes(self.pcm if length is None else self.pcm[:length])

    def discard(self, length):
        with self.condition:
            del self.pcm[:length]

    @property
    def size(self):
        with self.condition:
            return len(self.pcm)

    def finish(self):
        if self.closed:
            return
        self.closed = True
        self.process.stdin.close()
        try:
            return_code = self.process.wait(timeout=10)
        except subprocess.TimeoutExpired as error:
            self.process.kill()
            self.process.wait()
            raise ProtocolError(504, "audio decoder timed out") from error
        self.reader.join(timeout=2)
        if return_code != 0:
            raise ProtocolError(422, "audio decoder could not finalize the stream")

    def close(self):
        if not self.process.stdin.closed:
            try:
                self.process.stdin.close()
            except (BrokenPipeError, OSError):
                pass
        if self.process.poll() is None:
            self.closed = True
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.reader.join(timeout=2)
        self.process.stdout.close()

    def _read_output(self):
        while True:
            chunk = self.process.stdout.read(8192)
            if not chunk:
                break
            with self.condition:
                self.pcm.extend(chunk)
                self.condition.notify_all()
        with self.condition:
            self.condition.notify_all()


class Session:
    def __init__(self, options, decoder_factory=MediaDecoder):
        self.id = str(uuid.uuid4())
        self.content_type = options.get("content_type") or "application/octet-stream"
        self.language = options.get("language")
        self.prompt = options.get("prompt")
        self.next_sequence = 1
        self.input_bytes = 0
        self.committed_text = ""
        self.last_text = ""
        self.updated_at = time.monotonic()
        self.decoder = decoder_factory(self.content_type)
        self.lock = threading.Lock()

    def append(self, sequence, audio):
        with self.lock:
            if sequence != self.next_sequence:
                raise ProtocolError(409, f"expected chunk {self.next_sequence}")
            if self.input_bytes + len(audio) > MAX_BYTES:
                raise ProtocolError(413, "audio stream is too large")
            previous_size = self.decoder.size
            self.decoder.feed(audio)
            self.input_bytes += len(audio)
            self.next_sequence += 1
            self.updated_at = time.monotonic()
            if self.decoder.wait_for_growth(previous_size) == previous_size:
                return {"text": self.last_text}
            return self.hypothesis(final=False)

    def finish(self):
        with self.lock:
            if self.input_bytes == 0:
                raise ProtocolError(422, "audio stream is empty")
            self.decoder.finish()
            return self.hypothesis(final=True)

    def hypothesis(self, final):
        while self.decoder.size > INTERIM_WINDOW_BYTES:
            text = transcribe_pcm(self, self.decoder.snapshot(COMMIT_BYTES))
            self.committed_text = join_text(self.committed_text, text)
            self.decoder.discard(COMMIT_BYTES)

        remaining = self.decoder.snapshot()
        if len(remaining) < MIN_TRANSCRIBE_BYTES and not final:
            return {"text": self.last_text}
        tail = transcribe_pcm(self, remaining) if remaining else ""
        self.last_text = join_text(self.committed_text, tail)
        return {"text": self.last_text}

    def cleanup(self):
        self.decoder.close()


def join_text(prefix, suffix):
    return " ".join(part.strip() for part in (prefix, suffix) if part and part.strip())


def wav_bytes(pcm):
    output = io.BytesIO()
    with wave.open(output, "wb") as recording:
        recording.setnchannels(1)
        recording.setsampwidth(2)
        recording.setframerate(SAMPLE_RATE)
        recording.writeframes(pcm)
    return output.getvalue()


def multipart(fields, filename, content_type, content):
    boundary = uuid.uuid4().hex
    parts = []
    for name, value in fields.items():
        if value:
            parts.extend([
                f"--{boundary}\r\n".encode(),
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode(),
                str(value).encode(), b"\r\n",
            ])
    parts.extend([
        f"--{boundary}\r\n".encode(),
        f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'.encode(),
        f"Content-Type: {content_type}\r\n\r\n".encode(), content, b"\r\n",
        f"--{boundary}--\r\n".encode(),
    ])
    return boundary, b"".join(parts)


def transcribe_pcm(session, pcm):
    boundary, body = multipart(
        {"response_format": "json", "language": session.language, "prompt": session.prompt},
        "dictation.wav", "audio/wav", wav_bytes(pcm),
    )
    request = urllib.request.Request(
        UPSTREAM + "/inference", body,
        {"Content-Type": f"multipart/form-data; boundary={boundary}"}, method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            return str(json.load(response).get("text", "")).strip()
    except (urllib.error.URLError, ValueError) as error:
        raise ProtocolError(502, "transcription backend failed") from error


sessions = {}
sessions_lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Paths contain opaque session ids only. Never log bodies/audio/text.
        print("whisper gateway: " + fmt % args, flush=True)

    def do_GET(self):
        if self.path != "/health":
            return self.error(404, "not found")
        try:
            with urllib.request.urlopen(UPSTREAM + "/health", timeout=2) as response:
                healthy = response.status == 200
        except urllib.error.URLError:
            healthy = False
        self.respond(200 if healthy else 503, {
            "status": "ok" if healthy else "starting",
            "capabilities": {"batch": healthy, "streaming": healthy},
        })

    def do_POST(self):
        try:
            if self.path == "/inference":
                return self.proxy_inference()
            if self.path == "/stream/sessions":
                session = Session(self.read_json())
                with sessions_lock:
                    sessions[session.id] = session
                return self.respond(201, {"id": session.id})
            session_id, action = self.stream_path()
            if action != "finish":
                raise ProtocolError(404, "not found")
            session = take_session(session_id)
            try:
                return self.respond(200, session.finish())
            finally:
                session.cleanup()
        except (ValueError, ProtocolError) as error:
            if isinstance(error, ValueError):
                error = ProtocolError(400, "invalid request")
            self.error(error.status, error.message)

    def proxy_inference(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > MAX_BYTES + 64 * 1024:
            raise ProtocolError(413, "invalid inference request size")
        request = urllib.request.Request(
            UPSTREAM + "/inference", self.rfile.read(length),
            {"Content-Type": self.headers.get("Content-Type", "application/octet-stream")}, method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                body = response.read()
                self.send_response(response.status)
                self.send_header("Content-Type", response.headers.get("Content-Type", "application/json"))
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        except urllib.error.HTTPError as error:
            raise ProtocolError(error.code, "transcription backend failed") from error
        except urllib.error.URLError as error:
            raise ProtocolError(502, "transcription backend failed") from error

    def do_PUT(self):
        try:
            session_id, sequence = self.chunk_path()
            session = find_session(session_id)
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > MAX_BYTES:
                raise ProtocolError(413, "invalid audio chunk size")
            self.respond(200, session.append(sequence, self.rfile.read(length)))
        except (ValueError, ProtocolError) as error:
            if isinstance(error, ValueError):
                error = ProtocolError(400, "invalid request")
            self.error(error.status, error.message)

    def do_DELETE(self):
        try:
            session_id, action = self.stream_path(allow_empty=True)
            if action:
                raise ProtocolError(404, "not found")
            take_session(session_id).cleanup()
            self.respond(200, {"cancelled": True})
        except ProtocolError as error:
            self.error(error.status, error.message)

    def stream_path(self, allow_empty=False):
        parts = self.path.strip("/").split("/")
        if len(parts) not in ([3, 4] if allow_empty else [4]) or parts[:2] != ["stream", "sessions"]:
            raise ProtocolError(404, "not found")
        return parts[2], parts[3] if len(parts) == 4 else ""

    def chunk_path(self):
        parts = self.path.strip("/").split("/")
        if len(parts) != 5 or parts[:2] != ["stream", "sessions"] or parts[3] != "chunks":
            raise ProtocolError(404, "not found")
        return parts[2], int(parts[4])

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length) or b"{}")

    def respond(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def error(self, status, message):
        self.respond(status, {"error": message})


def find_session(session_id):
    with sessions_lock:
        session = sessions.get(session_id)
    if not session:
        raise ProtocolError(404, "stream session not found")
    return session


def take_session(session_id):
    with sessions_lock:
        session = sessions.pop(session_id, None)
    if not session:
        raise ProtocolError(404, "stream session not found")
    return session


def reap_sessions():
    while True:
        time.sleep(5)
        cutoff = time.monotonic() - SESSION_TIMEOUT
        with sessions_lock:
            expired = [key for key, value in sessions.items() if value.updated_at < cutoff]
            removed = [sessions.pop(key) for key in expired]
        for session in removed:
            session.cleanup()


if __name__ == "__main__":
    whisper = subprocess.Popen([
        "/usr/local/bin/whisper-server", "--host", "127.0.0.1", "--port", "8081",
        "--model", "/opt/whisper/models/ggml-base.en.bin", "--convert", "--tmp-dir", "/tmp/whisper-stt",
    ])
    threading.Thread(target=reap_sessions, daemon=True).start()
    try:
        ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
    finally:
        whisper.terminate()
        whisper.wait(timeout=10)
        with sessions_lock:
            remaining = list(sessions.values())
            sessions.clear()
        for session in remaining:
            session.cleanup()
