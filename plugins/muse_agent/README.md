# Muse Agent

Muse Agent connects Syrus workflow execution to Muse Code.

This plugin owns the credential surface, provider registration, and low-level
Muse process invocation adapter:

- `User#muse_api_key` encrypted storage
- `/credentials` save, clear, and test support
- a `CredentialProbe` registration while the plugin is enabled
- secret extraction so probe output and logs redact the saved key
- `MuseInvocation`, a fixture-backed wrapper for `muse exec --json`
- `AgentProviders::Muse`, registered through the `:agent_provider` plugin
  extension point

Chat execution is not registered yet.

The credential probe verifies that `muse` is available and runs:

```sh
muse exec --api-key-stdin "Reply with OK."
```

The API key is passed on stdin, never in argv.

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

Workflow runs set `HOME` to a per-workflow Muse home and write
`~/.config/muse/settings.json` with the `syrus-mcp-sidecar` stdio server before
launching `muse exec`. Muse required-tool steps fail fast with
`mcp_sidecar_failed` when the JSONL stream does not show the required Syrus MCP
tools as available or called.

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
