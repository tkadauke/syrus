# Chat speech-to-text

Live dictation uses `ChatDictationChannel` over ActionCable. Dictation starts
before a chat message exists, so it intentionally does not reuse
`stream_chat_turn`, which is coupled to a submitted user message and
`ChatTurnJob`.

ActionCable fits the Rails, browser, and Electron deployment shape better than
HTTP upload chunks plus a separate SSE response because the browser needs one
bidirectional, authenticated connection for `start`, ordered `audio_chunk`,
`stop`, `cancel`, and transcript delta frames. Solid Cable is already the app's
cross-process cable adapter, and the same signed-in user/session boundary used
by other app channels scopes the dictation stream to one user and chat.

The stream is ephemeral. Syrus does not persist interim or final dictation text;
the frontend keeps the buffered audio blob while streaming so an `error` frame's
`fallback` payload can retry the existing backend batch endpoint.

## Backend deployment

Chat dictation is feature-gated by `chat_speech_to_text`. With the flag off,
all modes are reported unavailable. With the flag on and no backend provider
configured, the composer falls back to browser speech recognition when the
browser supports it.

The local/free backend provider is `whisper_cpp`:

```
SYRUS_STT_PROVIDER=whisper_cpp
SYRUS_STT_WHISPER_CPP_EXECUTABLE=/opt/whisper.cpp/build/bin/whisper-cli
SYRUS_STT_WHISPER_CPP_MODEL=/models/ggml-base.en.bin
SYRUS_STT_BACKEND_STREAMING=false
```

CPU-only deployments can use batch transcription, but latency depends heavily on
host CPU and model size. The bundled `whisper_cpp` adapter uses the CLI batch
path only; keep `SYRUS_STT_BACKEND_STREAMING=false` unless the configured
provider implements `stream_transcription` and can keep up with live audio.

The chat payload includes sanitized backend availability metadata:
`feature_disabled`, `provider_unset`, or no reason when the backend is usable.
Operators can inspect this payload, request errors, or logs to tell whether the
UI chose backend streaming, backend batch, browser fallback, or no mode.

Operational logs are structured as `chat_speech_to_text.*` events and include
mode, provider name, latency, fallback reason, and error class/code. They must
not include transcript text, prompts, uploaded audio bytes, executable paths, or
model paths.

Batch transcription via the `whisper_cpp` provider shells out through
`ProcessRunner`, so each invocation registers a `SpawnedProcess` row
(`kind: "chat_stt"`) visible in `/admin/processes` and `read_worker_health` —
operators can confirm a transcription actually ran, see its duration/outcome,
and kill a wedged invocation the same way as any other tracked subprocess. The
recorded command omits the per-request audio tempfile path (replaced with
`[audio]`) so local worker paths don't leak into the admin UI; the executable
and model paths are shown.
