# Chat speech-to-text

Chat microphone input is controlled by the `chat_speech_to_text` feature flag.
Set `SYRUS_STT_PROVIDER` to choose the server provider. When server speech
recognition is unavailable, supported browsers can fall back to browser speech
recognition.

The bundled `whisper_stt` plugin supplies the Whisper-backed provider and its
runtime. Operators see recording, transcription, completion, and failure state
in the composer; successful transcription inserts editable text before send.

Streaming frames, channel status handling, and log-event internals live in
[speech-to-text architecture](../../docs/engineering/architecture/chat-speech-to-text.md).
Daemon deployment and diagnosis live in the [speech-to-text
runbook](../../docs/engineering/operations/chat-speech-to-text.md).
