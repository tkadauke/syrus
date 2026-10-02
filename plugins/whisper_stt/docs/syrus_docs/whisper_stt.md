# Whisper Speech-to-Text

Whisper speech-to-text runs `whisper.cpp`'s `whisper-server` as a Plugin
Runtime managed service. The daemon loads the `ggml-base.en.bin` model once,
listens on the internal Plugin Runtime network, and reports readiness through
`/health`. It is disabled by default.

This plugin also registers the `whisper_stt` `speech_to_text_provider`. When
the plugin is enabled and Plugin Runtime reports the `whisper-stt` service as
healthy, chat dictation exposes backend batch transcription. The chat
microphone records browser audio and posts it to the daemon's `/inference`
endpoint as multipart form data. The daemon receives the audio as the `file`
field with `response_format=json`; Syrus forwards optional `language` and
`prompt` fields from the chat request.

The provider is batch-only. It does not implement backend streaming because
`whisper-server` answers one HTTP request at a time rather than producing the
incremental deltas required by `ChatSpeechToText::StreamingSession`.

## Requirements

- **Plugin Runtime**, which Whisper speech-to-text depends on, to run or
  locate the service.
- Enough CPU and memory for the `base.en` whisper.cpp model.

## Running The Service

**Docker Compose.** Enable Plugin Runtime and Whisper speech-to-text. The
runtime manager pulls `ghcr.io/tkadauke/syrus-plugin-whisper-stt` at the tag
matching your Syrus release and starts `whisper-server` on the project
network. The image includes `ffmpeg` and runs `whisper-server --convert`, so
browser audio formats such as WebM/Opus can be decoded by the daemon.

**Kubernetes.** Deploy the image yourself and set, on the Syrus web and
worker pods:

| Variable | Value |
| --- | --- |
| `SYRUS_PLUGIN_SERVICE_WHISPER_STT_URL` | e.g. `http://whisper-stt:8080` |

On Syrus, `SYRUS_WHISPER_STT_IMAGE` overrides the image Compose runs.

## Checking That It Works

After enabling, use Admin -> Plugin Services to inspect the `whisper-stt`
service. A healthy service answers `GET /health` with status 200 once the
model is loaded. During startup the service may report that the model is
still loading.

With the `chat_speech_to_text` feature flag on, a healthy service makes
`ChatSpeechToText::Capability.for(user:).backend_batch_available?` true. If the
plugin is disabled or the service has no usable Plugin Runtime endpoint,
backend batch dictation is unavailable and chat falls back to browser speech
recognition when the browser supports it.

Set `SYRUS_STT_PROVIDER=whisper_stt` when more than one speech-to-text provider
is installed and this daemon should be the selected backend.

## Disabling

Disabling removes the managed service on Compose and withdraws the
`speech_to_text_provider` from chat capability resolution. Because this plugin
does not persist a volume, disabling leaves no plugin-owned service data
behind.
