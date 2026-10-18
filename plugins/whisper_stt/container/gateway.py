#!/usr/bin/env python3
"""Session-oriented gateway in front of whisper-server.

MediaRecorder chunks are appended to one file. Every hypothesis is decoded
from that complete recording prefix; a continuation chunk is never submitted
as an independent WebM file.
"""

import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "0.0.0.0"
PORT = int(os.environ.get("WHISPER_GATEWAY_PORT", "8080"))
UPSTREAM = os.environ.get("WHISPER_UPSTREAM_URL", "http://127.0.0.1:8081")
MAX_BYTES = 10 * 1024 * 1024
SESSION_TIMEOUT = 120


class Session:
    def __init__(self, options):
        self.id = str(uuid.uuid4())
        self.content_type = options.get("content_type") or "application/octet-stream"
        self.language = options.get("language")
        self.prompt = options.get("prompt")
        self.next_sequence = 1
        self.updated_at = time.monotonic()
        self.directory = tempfile.mkdtemp(prefix="whisper-stream-")
        extension = ".ogg" if self.content_type == "audio/ogg" else ".webm"
        self.path = os.path.join(self.directory, "recording" + extension)
        self.lock = threading.Lock()

    def append(self, sequence, audio):
        with self.lock:
            if sequence != self.next_sequence:
                raise ProtocolError(409, f"expected chunk {self.next_sequence}")
            current = os.path.getsize(self.path) if os.path.exists(self.path) else 0
            if current + len(audio) > MAX_BYTES:
                raise ProtocolError(413, "audio stream is too large")
            with open(self.path, "ab") as recording:
                recording.write(audio)
            self.next_sequence += 1
            self.updated_at = time.monotonic()
            return transcribe(self)

    def finish(self):
        with self.lock:
            if not os.path.exists(self.path):
                raise ProtocolError(422, "audio stream is empty")
            return transcribe(self)

    def cleanup(self):
        shutil.rmtree(self.directory, ignore_errors=True)


class ProtocolError(Exception):
    def __init__(self, status, message):
        self.status = status
        self.message = message


sessions = {}
sessions_lock = threading.Lock()


def multipart(session):
    boundary = uuid.uuid4().hex
    parts = []

    def field(name, value):
        if value:
            parts.extend([f"--{boundary}\r\n".encode(), f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode(), str(value).encode(), b"\r\n"])

    field("response_format", "json")
    field("language", session.language)
    field("prompt", session.prompt)
    parts.extend([
        f"--{boundary}\r\n".encode(),
        b'Content-Disposition: form-data; name="file"; filename="dictation.webm"\r\n',
        f"Content-Type: {session.content_type}\r\n\r\n".encode(),
    ])
    with open(session.path, "rb") as audio:
        parts.append(audio.read())
    parts.extend([b"\r\n", f"--{boundary}--\r\n".encode()])
    return boundary, b"".join(parts)


def transcribe(session):
    boundary, body = multipart(session)
    request = urllib.request.Request(
        UPSTREAM + "/inference", body,
        {"Content-Type": f"multipart/form-data; boundary={boundary}"}, method="POST"
    )
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            payload = json.load(response)
            return {"text": str(payload.get("text", "")).strip()}
    except (urllib.error.URLError, ValueError) as error:
        raise ProtocolError(502, "transcription backend failed") from error


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
        self.respond(200 if healthy else 503, {"status": "ok" if healthy else "starting", "capabilities": {"batch": healthy, "streaming": healthy}})

    def do_POST(self):
        try:
            if self.path == "/inference":
                return self.proxy_inference()
            if self.path == "/stream/sessions":
                options = self.read_json()
                session = Session(options)
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
            {"Content-Type": self.headers.get("Content-Type", "application/octet-stream")}, method="POST"
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
            session = take_session(session_id)
            session.cleanup()
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
        "--model", "/opt/whisper/models/ggml-base.en.bin", "--convert", "--tmp-dir", "/tmp/whisper-stt"
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
