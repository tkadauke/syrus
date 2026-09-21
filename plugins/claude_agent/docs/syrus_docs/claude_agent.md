# Claude Agent

The `claude_agent` plugin (`plugins/claude_agent/`) connects Syrus workflow
Runs and chat turns to the Claude Code CLI. It is customer-facing but
installed disabled by default for new installs (`default_enabled: false`,
`disableable: true`, category `agent_provider`), and provides both an
`agent_provider` (`AgentProviders::Claude`) and a `chat_provider`
(`ChatProviders::Claude`).

## Invocation (`ClaudeInvocation`)

`ClaudeInvocation` spawns:

```
claude --print [--mcp-config <path>] [--resume <id>] [--model <id>]
  [--disallowedTools ...] [--file <path> ...] --output-format stream-json
  --verbose --dangerously-skip-permissions [--max-turns N] [--effort <level>]
```

The prompt is sent over **stdin**, never as a positional argument — a large
prompt (e.g. an `adversarial_review` step embedding a full diff) can exceed
Linux's 128 KiB `MAX_ARG_STRLEN` and fail with `Errno::E2BIG`. `--mcp-config`
and `--resume` are always slotted between two flags, never immediately before
the prompt, avoiding the old variadic-arg hazard entirely once there is no
trailing positional. `--dangerously-skip-permissions` is safe here because the
agent only ever runs against an isolated per-Job worktree, never the
operator's own checkout. `max_turns` of `0`/`nil` omits `--max-turns`
entirely (uncapped turns; the process wall-clock timeout still bounds runaway
loops). Chat image attachments are not passed via a `--image` flag — Claude
Code has none — they are saved into the workspace and referenced as file
paths in the prompt for the agent's normal read tools; `--file` is used for
that.

`process_event` parses each `stream-json` line and streams it to `log_sink`
with a `kind:` tag the UI can filter by: `assistant_text`, `tool_call`
(abbreviated `tool_use`), `tool_result`, `thinking`, and `system` (meta lines
including the `[result]`/`[mcp_tools_init]`/`[mcp_servers]` markers). Logging
`tool_call`/`tool_result` alongside `assistant_text` matters for heartbeat
reliability — a step doing many consecutive Bash calls with no narrative text
used to look silent and could trip the reaper.

**Required-MCP-tool enforcement.** `ClaudeInvocation` accepts
`required_mcp_tools:` and inspects the `system`/`init` event's `mcp_servers`
and `tools` lists. If a required tool is missing from the init tool list, or
the `syrus-mcp-sidecar` server's status is neither `connected` nor `pending`,
the run is forced into an error outcome (`mcp_sidecar_failed`) rather than
letting the agent proceed silently without a tool it needs (e.g.
`submit_summary` on an `initial` Workflow). A `status: "failed"` MCP server
with no required-tools list configured is treated the same way.

**API errors and usage limits.** Assistant events carrying
`isApiErrorMessage`/`apiErrorStatus`/`error` are classified before anything
else: a 401 or `authentication_failed` becomes a clear
"refresh your Claude OAuth token" message; anything matching
`ProviderUsageLimit.detect?` is tagged with `ProviderUsageLimit::OUTCOME` so
downstream admission/retry logic can back off instead of retrying a doomed
run.

## Agent provider (`AgentProviders::Claude`)

`provider_key` is `"claude"`; `configured_for_user?` checks
`user.claude_oauth_token.present?`. `mcp_tool_name` builds
`mcp__<server_name>__<tool_name>` — Claude Code's own MCP tool-naming
convention, which is also why the sidecar's MCP config key must be exactly
`syrus-mcp-sidecar` (Claude derives resumed MCP tool prefixes from the config
key/binary basename).

`available_models` returns rough categorical metadata (Opus 4.7 / Sonnet 4.6
/ Haiku 4.5 with `context_window`/`cost_tier`) for a future model-routing
system — not exact pricing data, and not necessarily the exact identifiers
`--model` accepts long-term.

**MCP transport.** `with_mcp_config` writes a per-Run `mcp.json` tempfile.
Two shapes:

- **stdio** (default): `type: "stdio"`, `command`, `args`, `env`,
  `alwaysLoad: true`.
- **persistent**: `type: "http"`, pointed at `PersistentMcpDaemon`'s HTTP
  endpoint, with a signed `McpInvocationContext` token carried as a header
  (not `_meta` — Claude builds the JSON-RPC body itself, so there's no config
  surface to set `_meta` directly; the daemon injects it from the header on
  its side) — chosen by `mcp_transport_decision` (shared with other
  providers).

`alwaysLoad: true` (claude-code v2.1.121+) keeps
`mcp__syrus-mcp-sidecar__submit_summary` and friends in the agent's active
tool list at all times, including on `--resume`d sessions — without it,
Claude routed MCP tools through a deferred tool-search catalog and a resumed
agent sometimes couldn't find them.

**Session capture.** `session_capture` validates `result.session_id` against
`SESSION_ID_PATTERN` (`[A-Za-z0-9_-]+`), then reads the on-disk JSONL from
`ClaudeAgent::SessionPaths.canonical_path_for` (see below). Missing or
invalid session ids produce a `SessionCapture` with `missing_message` set
instead of raising — session continuation degrades gracefully rather than
failing the Run.

## Session file layout (`ClaudeAgent::SessionPaths`)

Claude Code stores each session's JSONL at
`~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`, where `<encoded-cwd>`
is the absolute working directory with every `/` **and** every `.` replaced
by `-` (verified empirically against a running worker — e.g.
`/syrus-home/.syrus/workflows/124` becomes
`-syrus-home--syrus-workflows-124`, a double dash from the `/.` pair).
Subagent (Task/Agent tool) conversations are **not** interleaved into that
main transcript in SDK/headless mode — Claude writes them to sibling
`<session-uuid>/subagents/agent-<id>.jsonl` files, each paired with an
`agent-<id>.meta.json` carrying the spawning `toolUseId`.

`ChatProviders::Claude#session_capture` merges those subagent files back into
one chronological JSONL stream (stamping `parentToolUseId` on each merged
line, sorted by timestamp with index as a stable tiebreaker) before handing
it to `ClaudeTranscript` — otherwise subagent activity is invisible in the
captured transcript entirely.

## Chat provider (`ChatProviders::Claude`)

Disallowed tools differ by chat mode: planning-mode chats block
`Write`/`Edit`/`MultiEdit`/`NotebookEdit`/`AskUserQuestion` (the agent should
never mutate a read-only attached checkout); Coding Mode only blocks
`NotebookEdit`/`AskUserQuestion` since the agent implements directly there.

**Stale-resume recovery.** `claude --resume <id>` hard-fails at startup
(`is_error`, zero turns, "No conversation found with session ID") when the
on-disk conversation is gone — worker restart, session expiry, session-file
format drift. `invoke` detects this specific shape
(`stale_resume_failure?`: `is_error && turns == 0 &&
outcome == "error_during_execution"`) and retries **once** without
`--resume`, prepending the full chat system prompt (a resumed session already
carries it; a fresh one does not) plus a DB-backed recovery transcript
(`ChatHistoryTranscriptRenderer.resume_recovery`) so the fresh session stays
coherent. During the first attempt, a `filtered_log_sink` swallows the scary
"No conversation found" noise from the live stream so a clean recovery
doesn't strand a visible error in the thread; a genuine mid-turn failure
(`turns > 0`) is never filtered. Without this, every chat would break after
any worker restart, not just long-running ones.

## OAuth (`ClaudeOauth`)

Drives the same PKCE (S256, no client secret) subscription OAuth flow
`claude setup-token` uses, so an operator can mint a `CLAUDE_CODE_OAUTH_TOKEN`
from inside Syrus instead of a terminal. The constants (`CLIENT_ID`, the
`claude.ai`/`console.anthropic.com` endpoints) are Claude Code's first-party
public OAuth client, reverse-engineered and not officially published for
third-party reuse — treat them as subject to change. The client only
whitelists a provider-hosted callback that displays a `code#state` string for
copy/paste; a loopback redirect to Syrus itself is rejected with "Redirect
URI is not supported," so Syrus implements the copy-and-paste flow rather
than a same-host callback.

## Credential probing and usage (`ClaudeCredentialProbe`, `ClaudeUsageProbe`)

`ClaudeCredentialProbe` runs `claude --print --max-turns 1 "Reply with OK."`
in a scratch tmpdir. `.call` uses the saved `claude_oauth_token`; `.cli_ready`
(`ambient: true`) probes with no token injected at all, letting the setup
wizard detect a working bare-metal CLI login before asking for a token.

`ClaudeUsageProbe` is a proactive ground-truth signal: since there is no
local `auth.json` to read structured usage from (unlike Codex), it makes a
minimal `POST /v1/messages` call (1 max token, `claude-haiku-4-5-20251001`,
the `oauth-2025-04-20` beta header — required for a Claude Code OAuth token
on this endpoint) and reads Anthropic's "unified" rate-limit response headers
(`anthropic-ratelimit-unified-5h-utilization` /
`anthropic-ratelimit-unified-7d-utilization` and their `-reset` companions —
the same headers `claude` itself observes on every inference call).
Classification: `exhausted` at ≥100% utilization on either window, `warning`
at ≥85%, else `available`. Results are cached via `ProviderAvailabilityEvidence`
and considered stale after 10 minutes (`STALE_AFTER`); `refresh_stale_usage!`
only probes when actually stale, `refresh_usage!(force: true)` bypasses that.

## Secret handling

`ClaudeCredentialProbe::SECRET_EXTRACTOR` (`->(user) { user.claude_oauth_token
}`) is registered with `CredentialProbe.register_secret_extractor` so process
output, transcripts, and logs redact the token. Admin user filtering gets a
`has_claude_token` chip (`Filters::Chips::AdminUsers::HasClaudeToken`).

## What's not here

Claude currently has no structured "remaining credit" display beyond the
5h/weekly percentages above, and no in-app indicator of which billing pool
(subscription vs. pay-as-you-go) a saved token draws from — see the
`muse_agent` docs for the analogous gap on that provider.
