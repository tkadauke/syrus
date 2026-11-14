# MCP Tool Usage

The generated MCP tool inventory lives in
`config/syrus_docs/mcp_tool_catalog.md`; update it with
`bin/surface-catalogs` after registry changes.

SQL-backed MCP list and transcript tools normalize one-based `page` inputs
through a shared pagination policy. Values below 1 become page 1, ordinary
pages beyond the available results return an empty page, and values above
10,000 are capped at 10,000 before an SQL `OFFSET` is calculated. Per-page
limits remain tool-specific. This bound applies to the core chat/repository
and transcript readers as well as the Operator Briefing and Agent Insights
pagination tools.

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
`syrus-mcp-sidecar.submit_summary` for Codex or Muse. Required-tool prompts should tell
the agent to call the exact name shown in its tool list; a bare call such as
`submit_summary` can fail when the sidecar is connected but the tool was
advertised under a prefixed name.

Workflow implementation agents also get `run_target_prepare`, a mutation tool
for explicitly running a compiled TargetGraph `kind: prepare` target after the
agent discovers it needs that project environment. Its durable audit trail is
the workflow artifact `target_prepare_requests`; MCP usage rows still record
the tool call itself the same way as other workflow-sidecar tools.

Usage recording, retention, startup timing, and the admin usage surface are
documented in the [engineering architecture reference](../../docs/engineering/architecture/mcp-tool-usage.md).
