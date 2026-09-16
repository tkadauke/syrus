# Antigravity Provider

Syrus can run workflow and chat turns through the Antigravity `agy` CLI when the
`agy_agent` plugin is installed and enabled. The provider key is `agy`; the UI
label is `Antigravity`.

## Runtime Requirements

- Worker hosts must have `agy` on `PATH`. The Docker worker image includes the
  pinned Antigravity CLI, so Docker Compose deployments should rebuild or pull a
  current worker image before enabling this provider.
- Users select Antigravity with the same agent/chat provider controls as Claude
  and Codex. A user is considered configured for Antigravity when their Gemini
  API key is saved.
- Syrus passes the saved key as both `GEMINI_API_KEY` and `GOOGLE_API_KEY`.
- Optional defaults: `SYRUS_AGY_MODEL` and `SYRUS_AGY_EFFORT`. Syrus forwards
  them to the child process as `AGY_MODEL` and `AGY_EFFORT` too.

## Invocation Shape

Syrus invokes Antigravity with stream JSON I/O:

```bash
agy --input-format stream-json --output-format stream-json --print= --dangerously-skip-permissions --disable-slash-commands --print-timeout 90m
```

The prompt is written to stdin as NDJSON:

```json
{"event":"user","message":{"content":"..."}}
```

This keeps large prompts off argv. Antigravity's print timeout is set to `90m`;
Syrus still uses the normal `AgentInvocation` process timeout, silent-timeout,
stop, and aliveness supervision as the outer control plane.

## MCP Behavior

Antigravity reads MCP servers from `~/.gemini/config/mcp_config.json`. Syrus
writes that file inside the isolated per-run or per-chat Antigravity home and
uses stdio sidecars for workflow and chat tools. Persistent HTTP MCP routing is
not wired for Antigravity yet; any persistent decision is downgraded to stdio
with a `provider_unsupported` diagnostic.

Tool names in Antigravity init events use the `mcp(server/tool)` shape, so Syrus
normalizes them back to MCP-style names when logging tool calls and validating
required workflow tools.

## Resume Semantics

Syrus stores `init.conversation_id` as the provider session id and captures the
Antigravity JSONL transcript. On resume, Syrus restores that JSONL into
Antigravity's expected per-conversation path and invokes:

```bash
agy --conversation <conversation_id> ...
```

Invalid conversation ids are ignored and the next turn starts fresh rather than
placing an unsafe value on argv. If stored JSONL is unavailable, Syrus logs a
resume warning and still passes the conversation id so Antigravity can attempt
provider-side continuation.

## Smoke Test

Run:

```bash
bin/smoke-agy
```

The helper verifies `agy --version`. If neither `GEMINI_API_KEY` nor
`GOOGLE_API_KEY` is present, it exits successfully after skipping the
authenticated probe. When a key is present, it sends a tiny stream-json prompt
through stdin and requires a `result` event from `agy`.
