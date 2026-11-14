# Chat Speech-to-Text Architecture

User-facing provider selection and fallback behavior are documented in the
[searchable speech-to-text guide](../../../config/syrus_docs/chat_speech_to_text.md). Deployment and diagnosis belong in the [operations runbook](../operations/chat-speech-to-text.md).

## Streaming channel

Live dictation uses `ChatDictationChannel` over ActionCable. Dictation starts
before a chat message exists, so it intentionally does not reuse
`stream_chat_turn`, which is coupled to a submitted user message and
`ChatTurnJob`.

ActionCable gives the browser one bidirectional authenticated connection for
`start`, ordered `audio_chunk`, `stop`, `cancel`, and transcript-delta frames.
Solid Cable is the cross-process adapter, and the signed-in user/session
boundary used by other app channels scopes each dictation stream.

The stream is ephemeral. Syrus does not persist interim or final dictation
text. The frontend retains the buffered audio blob while streaming so an
`error` frame's `fallback` payload can retry the existing backend batch
endpoint.

Interim transcript frames replace the current hypothesis in place. A final
frame commits that range exactly once. Text already in the composer remains
outside the replaceable dictation range. Browser Web Speech results use the
same interim-replacement and final-commit behavior.

The microphone sends ordered chunks while retaining the continuous recording
for batch fallback. The Whisper gateway feeds chunks to one persistent media
decoder per session and emits revised hypotheses from a bounded PCM window;
arbitrary WebM continuation fragments are not decoded independently and
inference input does not grow without bound.

Disconnect, cancel, idle timeout, normal finalization, and provider-error paths
close the provider session.

## Capability and status payloads

`ChatSpeechToText::Providers.configured` resolves an enabled, currently
available `speech_to_text_provider`. The chat payload exposes only sanitized
availability metadata: `feature_disabled`, `provider_unset`, or no reason when
the backend is usable.

Batch recordings under 256 bytes are rejected as `audio_too_small` (422).
Backend timeouts return `speech_to_text_timeout` (504), and unavailable
backends return `speech_to_text_backend_unavailable` (503). The composer retries
either backend status once, does not retry 4xx input errors, and preserves
existing or progressive composer text when finalization fails.

## Operational events

Operational logs use `chat_speech_to_text.*` event names and include mode,
provider name, latency, fallback reason, and error class/code. They must not
include transcript text, prompts, uploaded audio bytes, executable paths, or
model paths. Provider-specific diagnostics belong in provider-owned docs.

Admin chat exposes these events through `admin_read_operational_logs`. The tool
wraps `OperationalLogIndex.search` with the shared query, time, severity, role,
hostname, limit, disabled-response, redaction, and row-rendering behavior in
`OperationalLogSearch`. Unlike the workflow-scoped `read_syrus_logs`, it is
available from any admin chat session and does not require an attached Syrus
repository.
