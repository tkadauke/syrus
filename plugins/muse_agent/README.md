# Muse Agent

Muse Agent connects Syrus workflow and chat execution to Muse Code.

Muse is intentionally shipped as an installed but disabled plugin until an
operator enables it for an instance. Turn it on from **Admin -> Plugins ->
Muse Agent** after the worker/backend image has the `muse` CLI on `PATH` and
the pilot users have saved Muse API keys. Turning the plugin off removes Muse
from agent/chat provider selection and disables its credential probe for new
requests without deleting saved encrypted keys.

This plugin owns the credential surface, provider registration, and low-level
Muse process invocation adapter:

- `User#muse_api_key` encrypted storage
- `/credentials` save, clear, and test support
- a `CredentialProbe` registration while the plugin is enabled
- secret extraction so probe output and logs redact the saved key
- `MuseInvocation`, a fixture-backed wrapper for `muse exec --json`
- `AgentProviders::Muse`, registered through the `:agent_provider` plugin
  extension point
- `ChatProviders::Muse`, registered through the `:chat_provider` plugin
  extension point
- `ChatSessionRehydrator::Muse`, which rebuilds Muse-shaped JSONL from durable
  chat messages for provider switching and context compaction

Muse appears as a selectable workflow or chat provider when the plugin is
enabled and the user has a saved Muse API key.

Keys are created at <https://ai.developer.meta.com/> under **API keys** and
begin with `LLM|`. The value is shown once and cannot be revealed or rotated
later; an operator who has lost one but signed in through `muse login` can
recover it from the CLI's credential store (`ai.meta.dev.credentials` in macOS
Keychain Access) and paste that JSON document straight into the credential
field, which keeps only its `api_key`. See
`docs/syrus_docs/muse_agent.md` for the full credential and billing notes.

The credential probe verifies that `muse` is available and runs:

```sh
muse exec --json --provider meta --api-key-stdin "Reply with OK."
```

The API key is passed on stdin, never in argv.

For a no-credential CLI smoke test, run:

```sh
muse exec --json --provider echo "Reply with OK."
```

For a credentialed provider smoke test, run:

```sh
printf '%s' "$MUSE_API_KEY" | muse exec --json --provider meta --api-key-stdin "Reply with OK."
```

## Invocation contract

`MuseInvocation` runs:

```sh
muse exec --json --provider meta --workspace <path> \
  --approval-mode never --user-input-auto-resolve \
  --session-id <uuid> --prompt-file <file> --api-key-stdin
```

It appends `--model`, `--reasoning-effort`, and `--max-model-steps` only when
configured. The prompt is written to a temporary file and the API key is sent
over stdin so neither secret appears in argv.

Workflow runs set `HOME` to a per-workflow Muse home. Chat turns set `HOME` to
a per-chat Muse home. Both paths write `~/.config/muse/settings.json` with the
appropriate Syrus stdio MCP sidecar before launching `muse exec`. Muse
required-tool workflow steps fail fast with `mcp_sidecar_failed` when the JSONL
stream does not show the required Syrus MCP tools as available or called.

The adapter streams Muse JSONL envelopes to the run log and parses terminal
events such as `run.terminal.completed` and `run.terminal.failed` into
`AgentInvocation::Result`. Internal `task.lifecycle.failed` events are logged
as diagnostics only; the enclosing terminal event and process status decide
the result.

Transcript capture is explicit:

- `:redacted_export` (default) runs `muse export --session <uuid> --redacted --out <file>`.
- `:raw_export` runs `muse export --session <uuid> --out <file>`.
- `:exec_jsonl` stores the raw exec JSONL stream captured during the run.

If export fails, the adapter falls back to the exec JSONL stream and logs a
diagnostic. Raw capture therefore requires an explicit policy choice.

Chat turns capture the exec JSONL stream for resumable provider sessions.
If a stale Muse session fails before any turn runs, Syrus retries once as a
fresh session using the chat-history fallback in the prompt. Disposable scoped
event evaluator sessions include the rehydrated transcript context in the
prompt because Muse does not currently expose a separate transcript import flag.

## Rollout notes

Muse differs from Claude and Codex in three operator-visible ways:

- Muse API credentials are API keys saved per Syrus user, issued either by a
  Muse subscription or pay-as-you-go; CLI availability and API credentials are
  separate requirements.
- Muse reads MCP servers from `~/.config/muse/settings.json`, so Syrus writes a
  per-workflow or per-chat Muse home and currently uses stdio sidecars rather
  than the persistent MCP HTTP transport.
- Muse JSONL uses a `payload_type` envelope that Syrus normalizes through
  `MuseAgent::TranscriptEvents`; transcript exports default to Muse's redacted
  export path and raw transcript capture is opt-in.

Known limitations:

- No structured Muse usage probe exists yet; provider usage, billing, and quota
  failures are classified reactively from invocation errors.
- Required workflow MCP tools fail fast only after Muse reports tool inventory
  or exits without using the required tools.
- Disposable chat evaluator sessions receive rehydrated transcript context in
  the prompt because Muse does not expose a separate transcript import flag.
