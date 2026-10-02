# Whisper Speech-to-Text

Whisper speech-to-text runs `whisper.cpp`'s `whisper-server` as a Plugin
Runtime managed service. The daemon loads the `ggml-base.en.bin` model once,
listens on the internal Plugin Runtime network, and reports readiness through
`/health`. It is disabled by default.

This plugin only provides the daemon. It does not yet register a
speech-to-text provider for chat dictation, so enabling it starts and
monitors the service but does not change the microphone button's behavior by
itself.

## Requirements

- **Plugin Runtime**, which Whisper speech-to-text depends on, to run or
  locate the service.
- Enough CPU and memory for the `base.en` whisper.cpp model.

## Running The Service

**Docker Compose.** Enable Plugin Runtime and Whisper speech-to-text. The
runtime manager pulls `ghcr.io/tkadauke/syrus-plugin-whisper-stt` at the tag
matching your Syrus release and starts `whisper-server` on the project
network. The image includes `ffmpeg` and runs `whisper-server --convert`, so
browser audio formats such as WebM/Opus can be decoded by the daemon once the
provider is wired in.

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

## Disabling

Disabling removes the managed service on Compose. Because this scaffold does
not persist a volume, disabling leaves no plugin-owned service data behind.
