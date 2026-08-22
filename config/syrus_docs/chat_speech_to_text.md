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
all modes are reported unavailable. With the flag on, the official
`syrus-backend` image works with zero extra env configuration: it bundles a
CPU-only whisper.cpp build and a default model at fixed paths
(`/opt/whisper.cpp/whisper-cli` and `/opt/whisper.cpp/models/ggml-base.en.bin`),
and `ChatSpeechToText::Providers.configured` uses those paths automatically
when `SYRUS_STT_PROVIDER`/`SYRUS_STT_WHISPER_CPP_EXECUTABLE`/
`SYRUS_STT_WHISPER_CPP_MODEL` are unset — but only if the baked-in files
actually exist, so bare-metal/non-bundled installs still correctly fall
through to browser speech recognition when the browser supports it.

The backend provider is `whisper_cpp`. All three env vars are optional
overrides, not required setup — set them to point at a different
binary/model (e.g. bare-metal installs or a custom model):

```
SYRUS_STT_PROVIDER=whisper_cpp
SYRUS_STT_WHISPER_CPP_EXECUTABLE=/opt/whisper.cpp/whisper-cli
SYRUS_STT_WHISPER_CPP_MODEL=/models/ggml-base.en.bin
SYRUS_STT_BACKEND_STREAMING=false
```

Explicit env vars always take precedence over the baked-in defaults. To use a
different model than the bundled `ggml-base.en.bin` (a larger model for
accuracy, a smaller one for speed, or a non-English model), download the
desired `ggml-*.bin` into the running container/volume and point
`SYRUS_STT_WHISPER_CPP_MODEL` at that path — the executable does not need to
change.

CPU-only deployments can use batch transcription, but latency depends heavily on
host CPU and model size. The bundled `whisper_cpp` adapter uses the CLI batch
path only; keep `SYRUS_STT_BACKEND_STREAMING=false` unless the configured
provider implements `stream_transcription` and can keep up with live audio.

### Building without the bundled binary/model

The Dockerfile's `whisper-build` stage compiles whisper.cpp from source and
downloads the default model, which adds build time and ~148MB to the image.
Operators building a custom, lean image that doesn't need local dictation
(e.g. they only use browser speech recognition, or plan to supply their own
`whisper_cpp` binary/model via the env vars above) can skip that stage with
the `SYRUS_SKIP_WHISPER_BUILD=1` build arg:

```
docker build --build-arg SYRUS_SKIP_WHISPER_BUILD=1 -t syrus-backend:lean .
```

This produces a stub `whisper-cli` that always fails, so
`ChatSpeechToText::Providers.configured` correctly falls back to browser
speech recognition (or a manually configured provider) instead of reporting a
broken backend as available. `bin/publish-image` and `bin/deploy` never set
this arg, so published/deployed images always bundle the real build; it's
meant for local dev loops (`bin/build-local-image`, `bin/compose-up` default
to it) and custom lean builds only.

### License note

The bundled whisper.cpp build (https://github.com/ggml-org/whisper.cpp) and
the ggml/OpenAI Whisper models it downloads are MIT-licensed.

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

## Querying STT operational logs from chat

The `chat_speech_to_text.*` operational log events above are queryable from an
admin chat session, not just via kubectl/log-scraping. `admin_read_operational_logs`
(`Mcp::Tools::AdminReadOperationalLogsTool`, registered `admin_only: true` in
`McpToolRegistry`) wraps `OperationalLogIndex.search` with the same
query/since/level/role/hostname/limit shape, `OperationalLogging.enabled_for_instance?`
disabled-response guard, and write-time redaction as the workflow/agent-insight
`read_syrus_logs` tool (`SyrusDev::ReadSyrusLogsTool`); the shared search and
row-rendering logic lives in `OperationalLogSearch`. Unlike `read_syrus_logs`,
it is not restricted to runs on a `tkadauke/syrus` repository — any admin chat
session, including Supervisor chats with no attached repository, can call it —
so an operator can ask "which STT mode fired for that transcription?" and get
an answer in seconds.
