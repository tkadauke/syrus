# Whisper Speech-to-Text

Whisper speech-to-text runs `whisper.cpp`'s `whisper-server` as a Plugin
Runtime managed service. The daemon loads the `ggml-base.en.bin` model once,
listens on the internal Plugin Runtime network, and reports readiness through
`/health`. It is disabled by default.

This plugin also registers the `whisper_stt` `speech_to_text_provider`. When
the plugin is enabled and Plugin Runtime reports the `whisper-stt` service as
healthy, chat dictation exposes backend streaming and batch transcription.
The image runs a compiled Go session gateway in front of `whisper-server`.
The minimal runtime contains no Python interpreter or gateway source. Each stream
owns one persistent `ffmpeg` process, so ordered MediaRecorder continuation
chunks pass through the same WebM/Ogg decoder state and are converted to PCM.
The gateway sends WAV snapshots from a bounded 15-second PCM window to
Whisper, periodically commits older 10-second windows, and emits the composed
revised hypothesis. It never submits a continuation fragment as an independent
recording or repeatedly decodes the accumulated media container. Stopping
flushes the decoder, transcribes the remaining bounded window, and terminates
the per-session process.
Live sessions accept the composer's WebM and Ogg recorder formats. Other audio
formats remain available through the batch `/inference` path.

The existing `/inference` multipart endpoint remains available through the
gateway. It receives audio as the `file` field with `response_format=json`;
Syrus forwards optional `language` and `prompt` fields.

Batch uploads smaller than 256 bytes are rejected by Rails as
`audio_too_small` (422) and never reach the daemon. The Rails client uses a
2-second connect timeout, 10-second write timeout, and 90-second read timeout;
the gateway uses a 90-second whole-upstream-request timeout. The gateway HTTP
server has a 10-second header timeout, while streaming sessions have a
120-second idle timeout. Upstream timeouts return `speech_to_text_timeout`
(504), and connection or availability failures return
`speech_to_text_backend_unavailable` (503). The composer retries those two
statuses once, never retries a 4xx response, and preserves existing and partial
composer text if finalization fails.
The gateway independently parses the multipart upload before proxying it. It
rejects a missing, empty, undersized, oversized, unsupported, or
signature-invalid audio part with a 4xx response, so malformed uploads cannot
surface as whisper.cpp availability failures.

Rails forwards its request ID as `X-Request-ID`. Gateway logs label the client
request as `ingress` and the whisper.cpp call as `upstream`, using the same ID;
neither log includes audio, prompts, or transcript text. Thus two lines for one
batch operation describe its two layers rather than duplicate client uploads.

## Requirements

- **Plugin Runtime**, which Whisper speech-to-text depends on, to run or
  locate the service.
- Enough CPU and memory for the `base.en` whisper.cpp model and concurrent
  session decodes. Each active stream owns an `ffmpeg` process and retains at
  most 15 seconds of decoded PCM plus committed transcript state; interim
  inference uses more CPU than a single batch request, but its input window
  does not grow with utterance length.

## Running The Service

**Docker Compose.** Enable Plugin Runtime and Whisper speech-to-text. The
runtime manager pulls `ghcr.io/tkadauke/syrus-plugin-whisper-stt` at the tag
matching your Syrus release and starts `whisper-server` on the project
network. The image includes `ffmpeg` and runs `whisper-server --convert`, so
browser audio formats such as WebM/Opus can be decoded by the daemon.
The Go gateway and `whisper-server` image are built for both supported target
architectures by the repository's multi-platform release build.

**Kubernetes.** Deploy the image yourself and set, on the Syrus web and
worker pods:

| Variable | Value |
| --- | --- |
| `SYRUS_PLUGIN_SERVICE_WHISPER_STT_URL` | e.g. `http://whisper-stt:8080` |

On Syrus, `SYRUS_WHISPER_STT_IMAGE` overrides the image Compose runs.

## Checking That It Works

After enabling, use Admin -> Plugin Services to inspect the `whisper-stt`
service. A healthy service answers `GET /health` with status 200 and reports
`capabilities.streaming: true` once the model is loaded. During startup the
service reports unavailable and chat does not advertise backend streaming.

With the `chat_speech_to_text` feature flag on, a healthy service makes
`backend_streaming_available?` and `backend_batch_available?` true. Stream
startup, ordering, decode, timeout, disconnect, and cancellation failures
release gateway resources. The composer retains the complete browser audio;
when possible, it automatically retries `/inference`, then uses browser speech
recognition if batch transcription also fails. Cancel, disconnect, error, and
idle-expiry paths terminate the session decoder process. Idle gateway sessions
expire after 120 seconds and ActionCable sessions time out after 30 seconds.

Set `SYRUS_STT_PROVIDER=whisper_stt` when more than one speech-to-text provider
is installed and this daemon should be the selected backend.

## Disabling

Disabling removes the managed service on Compose and withdraws the
`speech_to_text_provider` from chat capability resolution. Because this plugin
does not persist a volume, disabling leaves no plugin-owned service data
behind.
