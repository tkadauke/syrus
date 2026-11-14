# Speech-to-Text Operations

This runbook covers backend deployment and diagnosis. See
[speech-to-text architecture](../architecture/chat-speech-to-text.md) for the
ActionCable protocol, frames, statuses, and event design, and the
[searchable guide](../../../config/syrus_docs/chat_speech_to_text.md) for
operator-visible behavior.

## Deploying the backend

Chat dictation is feature-gated by `chat_speech_to_text`. Backend modes also
require an installed, enabled, and healthy `speech_to_text_provider` plugin.
The bundled `whisper_stt` plugin supplies the local whisper.cpp backend:

1. Enable Plugin Runtime.
2. Enable `whisper_stt`.
3. Wait for the `whisper-stt` service to become healthy.
4. Confirm `PluginRuntime::Services.endpoint_for("whisper-stt")` returns an
   endpoint and that the service health response advertises streaming.

Core provider selection can be pinned with:

```
SYRUS_STT_PROVIDER=whisper_stt
```

When unset, core selects the first available provider in plugin registration
order. The plugin's own
[`whisper_stt` documentation](../../../plugins/whisper_stt/docs/syrus_docs/whisper_stt.md)
owns daemon, model, container, and runtime setup details.

## Diagnosing availability

When the plugin is disabled or its daemon is absent, starting, unhealthy, or
unreachable, the capability payload reports backend batch unavailable with
`provider_unset`. Browser speech recognition can remain available. Inspect the
capability payload first to distinguish feature-disabled, provider-unset, and
healthy-backend states.

Use an admin chat's `admin_read_operational_logs` tool to query
`chat_speech_to_text.*` events by time, level, role, or hostname. Events show
the selected mode and provider, latency, fallback reason, and sanitized error
class/code. They deliberately omit audio and transcript content.

For provider-specific failures, inspect Plugin Runtime service health and the
plugin logs described in the plugin documentation. A 503
`speech_to_text_backend_unavailable` indicates provider availability; a 504
`speech_to_text_timeout` indicates a selected backend that did not complete in
time. Input errors such as `audio_too_small` are client/request problems and
are not retried.
