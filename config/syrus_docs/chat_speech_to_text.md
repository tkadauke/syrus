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
all modes are reported unavailable. With the flag on, Syrus core reports
browser speech recognition as available and resolves backend dictation through
enabled `speech_to_text_provider` plugins. If no plugin provider is installed,
enabled, and currently available, `ChatSpeechToText::Providers.configured`
returns nil and the UI falls back to browser speech recognition when the
browser supports it.

Backend batch dictation is available when a `speech_to_text_provider` plugin is
installed, enabled, and currently available. The bundled `whisper_stt` plugin
provides the local whisper.cpp backend: enable Plugin Runtime, enable
`whisper_stt`, and wait for its `whisper-stt` service to become healthy. Once
`PluginRuntime::Services.endpoint_for("whisper-stt")` has an endpoint, the chat
capability payload reports `modes.backend_batch.available: true` and the
microphone button sends browser audio to the daemon.

Without `whisper_stt`, with the plugin disabled, or while the daemon is absent,
starting, unhealthy, or otherwise unreachable through Plugin Runtime,
`ChatSpeechToText::Providers.configured` returns nil. The capability payload
then reports backend batch unavailable with `provider_unset`, while
`modes.browser.available` remains true when the feature flag is on. The UI uses
that payload to fall back to browser speech recognition when the browser
supports it.

Core only owns the provider-selection contract: `SYRUS_STT_PROVIDER` may pin a
plugin provider by `provider_key`; when unset, Syrus uses the first available
provider in plugin registration order. To pin the bundled daemon-backed
provider:

```
SYRUS_STT_PROVIDER=whisper_stt
```

See the plugin's own docs
(`plugins/whisper_stt/docs/syrus_docs/whisper_stt.md`) for daemon, model, and
runtime setup.

The chat payload includes sanitized backend availability metadata:
`feature_disabled`, `provider_unset`, or no reason when the backend is usable.
Operators can inspect this payload, request errors, or logs to tell whether the
UI chose backend streaming, backend batch, browser fallback, or no mode.

Operational logs are structured as `chat_speech_to_text.*` events and include
mode, provider name, latency, fallback reason, and error class/code. They must
not include transcript text, prompts, uploaded audio bytes, executable paths, or
model paths. Provider-specific diagnostics belong in the provider plugin's docs.

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
session, including one with no attached repository, can call it — so an
operator can ask "which STT mode fired for that transcription?" and get an
answer in seconds.
