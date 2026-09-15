# Antigravity Agent

Antigravity Agent connects Syrus workflows and chats to Google's `agy` CLI. It provides the provider adapter used for implementation, review, repair, coding handoff, and interactive chat sessions, while feeding provider availability and failure classification back into Syrus' admission and retry systems.

Enable this plugin when a Syrus instance should offer Antigravity-backed automation. It can run alongside the Claude and Codex plugins so jobs and chats choose the appropriate provider per workflow or conversation.

## What It Adds

- A workflow agent provider with provider key `agy` and display name `Antigravity`.
- A chat provider for Antigravity-backed chat turns.
- Provider readiness evidence through the shared Gemini API key credential.
- Transcript capture and session resume for Antigravity conversation JSONL.

## Requirements

- The `agy` CLI must be installed on worker hosts and available on `PATH`. The Docker worker image includes the pinned Antigravity CLI; Docker Compose operators should rebuild or pull an image that contains it before enabling this plugin.
- Each user who selects Antigravity needs a saved Gemini API key. Syrus stores that key in `User#gemini_api_key` and passes it to `agy` as `GEMINI_API_KEY` and `GOOGLE_API_KEY`.
- Optional model and effort defaults can be set with `SYRUS_AGY_MODEL` and `SYRUS_AGY_EFFORT`. Syrus also forwards them to the child process as `AGY_MODEL` and `AGY_EFFORT`.

## Invocation Contract

Syrus runs `agy` with stream JSON input and output:

```bash
agy --input-format stream-json --output-format stream-json --print= --dangerously-skip-permissions --disable-slash-commands --print-timeout 90m
```

Prompts are written to stdin as one NDJSON event:

```json
{"event":"user","message":{"content":"..."}}
```

This avoids putting large prompts or secrets on argv. Syrus keeps `AgentInvocation` as the outer timeout/aliveness supervisor and passes Antigravity's print timeout as `90m`.

## MCP And Resume

Antigravity reads MCP servers from `~/.gemini/config/mcp_config.json`. Syrus writes that config inside an isolated per-run or per-chat Antigravity home and currently uses stdio sidecars only; persistent HTTP MCP routing downgrades to stdio for this provider.

The `init.conversation_id` value is stored as the provider session id. On resume, Syrus restores the captured JSONL transcript into Antigravity's expected session path and invokes `agy --conversation <conversation_id>`. Invalid conversation ids are ignored and the turn starts fresh rather than placing unsafe values on argv.

## Smoke Test

Use the repository helper for local verification:

```bash
bin/smoke-agy
```

The helper verifies `agy --version`. If neither `GEMINI_API_KEY` nor `GOOGLE_API_KEY` is set, it exits successfully after reporting that the authenticated `--print` probe was skipped, keeping CI deterministic. When a key is present it sends a tiny stream-json prompt through stdin and requires a `result` event.

## Operational Notes

The Antigravity card in Credentials shares the Gemini API key card intentionally: the key remains the durable credential, while the Antigravity card probes whether that key and the local `agy` CLI can run provider turns.

See also `config/syrus_docs/antigravity.md` for the operator-facing setup reference indexed by Syrus docs search.
