# MCP Tool Usage

Syrus records MCP tool invocations from workflow agents and chat agents in
`mcp_tool_usages`. The table stores normalized tool identity, surface
(`workflow` or `chat`), server name when the provider exposes one, provider and
session identifiers, linked Job/Workflow/Run or ChatSession ids, user/repository
ids when derivable, start/completion timestamps, status, error flag/class, a
bounded error summary, input/result byte counts, and dispatch metadata
(`sidecar_mode`, `daemon_worker_id` — see "Sidecar mode" below).

The usage recorder intentionally does not persist full tool inputs or results.
Detailed transcript rendering remains backed by the existing run transcript and
chat message records.

Operators can inspect aggregate usage through:

- `GET /api/v1/app/admin/mcp_tool_usage`
- `GET /api/v1/admin/mcp_tool_usage`

Query parameters:

- `start` / `end`: ISO8601 time window. Defaults to the last 7 days and caps at
  90 days.
- `surface`: optional `workflow` or `chat` filter.
- `limit`: maximum rows returned for top-tool and error-rate sections, capped at
  100.

The response includes top tools, unused currently advertised tools for the
selected surface, error rates by tool, chat-vs-workflow usage breakdown
(`surface_breakdown`), and stdio-vs-persistent usage breakdown
(`sidecar_mode_breakdown`).

## Sidecar mode (`sidecar_mode`, `daemon_worker_id`)

`sidecar_mode` is `"stdio"` or `"persistent"` (`McpToolUsage::SIDECAR_MODES`),
recording which MCP transport actually served a given call — see
`persistent_mcp_sidecar.md` for the two transports themselves. Two recording
paths write to the same `mcp_tool_usages` table, and each call is recorded by
exactly one of them, never both, per invocation:

- **Transcript-derived (`sidecar_mode: "stdio"`)** — `Steps::Base` (workflow
  agentic steps) and `ChatTurnJob` observe `tool_call`/`tool_result` events in
  the agent CLI's own output stream and call
  `McpToolUsageRecorder.record_workflow_tool_call`/`record_chat_tool_call`
  (and their `_result` counterparts), which default `sidecar_mode` to
  `"stdio"`. This is the only recording path for workflow steps today (no
  workflow tool dispatch is wired onto the persistent daemon yet — see
  `persistent_mcp_sidecar.md`), and it stays the recording path for chat
  turns that used the stdio sidecars.
- **Dispatch-boundary (`sidecar_mode: "persistent"`)** — chat turns routed to
  `PersistentMcpDaemon` instead call
  `PersistentMcpDaemon::ChatToolDispatch`, which wraps every tool call with
  `McpToolUsageRecorder.record_dispatch` right at the point the daemon
  actually dispatches it. This is authoritative for persistent-mode chat
  calls: `ChatTurnJob#record_transcript_mcp_usage?` skips the
  transcript-derived path entirely for a turn whose
  `ChatMcpTransportSelector` decision was `:persistent`, so the two paths
  never double-count the same call. Being a synchronous request/response
  cycle rather than an observed two-event stream, the dispatch-boundary path
  also captures rejections a transcript would never show as a clean
  tool_result — an invalid/expired/wrong-worker `McpInvocationContext`
  token, or a tier/role authorization denial — as a `status: "failed"` row
  with `error_class` set and a bounded `error_message_summary`, even when no
  chat_session could be resolved (an invalid-context rejection happens
  before the token's chat session is known).

`daemon_worker_id` is set alongside `sidecar_mode: "persistent"` from
`PersistentMcpDaemon#identity`'s `worker_id` — the same stable per-worker id
used elsewhere for resume-queue routing — so usage from a specific worker's
daemon instance can be isolated when comparing modes.

Tool exposure metadata is declared in `McpToolRegistry`. Use
`McpToolRegistry.summaries(surface: ..., tier: ...)` when docs or usage payloads
need authoritative tool profile data such as surface, tier, admin-only status,
feature flag gates, required roles/capabilities, and read-only vs mutation
classification.

Workflow-sidecar health is intentionally visible in `JobLog` for agentic steps
that require MCP submission tools such as `submit_summary` or
`submit_test_plan`. Look for `[mcp_config]`, `[mcp_sidecar]`,
`[mcp_tools_init]`, `[mcp_required]`, `[mcp_required_health]`, and
`[mcp_sidecar_stderr]` rows when debugging "agent succeeded but did not call the
required tool" failures. These rows show the generated MCP config path,
forwarded env key names, sidecar startup/tool advertisement, Claude's init-time
tool list, transcript evidence for whether the required tool was available or
called, and the sidecar stderr tail.

Different agents expose workflow-sidecar tools with different fully qualified
names, such as `mcp__syrus-mcp-sidecar__submit_summary` for Claude and
`syrus-mcp-sidecar.submit_summary` for Codex. Required-tool prompts should tell
the agent to call the exact name shown in its tool list; a bare call such as
`submit_summary` can fail when the sidecar is connected but the tool was
advertised under a prefixed name.

Tool implementations live under `Mcp::Tools`, and the stdio server processes
are built through the shared `Mcp::Sidecar` infrastructure. Protocol-visible
server names remain stable: `syrus-chat-sidecar`,
`syrus-chat-deferred-sidecar`, and `syrus-mcp-sidecar`.
