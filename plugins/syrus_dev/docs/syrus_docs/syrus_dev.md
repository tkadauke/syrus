# Syrus Dev

The `syrus_dev` plugin (`plugins/syrus_dev/`) is tooling for developing Syrus
*itself*, not a general admin plugin: performance diagnostics (slow
requests/jobs/phases/browser traces/SQL fingerprints with revision-over-
revision comparison), an operational-log search page, a SQL `EXPLAIN`
helper, and workflow MCP tools that let Syrus-development agents read
sanitized runtime diagnostics and log data about the very instance they're
running on. It is a self-contained Rails engine plugin, installed but
disabled by default (`default_enabled: false`, `disableable: true`,
category `tooling`). Keep it disabled on ordinary customer/project
installations — it exists to make Syrus better at building and debugging
Syrus.

## Configuration

No credentials or `config_schema`. The plugin is a thin presentation/tool
layer over core observability infrastructure that already exists whether or
not the plugin is enabled:

- **Performance diagnostics** come from `PerformanceLogging` /
  `PerformanceLogging::Store` (an in-memory/short-retention event buffer,
  gated by the separate `PerformanceLogging::FEATURE_SLUG` feature flag —
  the plugin only adds the *surface* to read it, and reports
  `enabled: false` in its payload when that flag is off).
- **Operational logs** come from `OperationalLogging` (gated by
  `OperationalLogging.enabled_for_instance?`); when it's off, both the
  `/admin/operational_logs` admin page and the `read_syrus_logs` MCP tool
  are withheld/return a disabled response rather than erroring.

Every controller action and both `PerformancePayload`/`SqlExplain` calls run
inside `PerformanceLogging.suppress`/`OperationalLogging.suppress` so
inspecting performance/log data doesn't itself generate more performance/log
events.

## Admin pages

Both under group `observability`, present only when their underlying
feature is on:

- **Admin → Performance** (`/admin/performance`) — renders
  `SyrusDev::PerformancePayload`: per-revision (or all-retained-revisions,
  via `revision_scope=all`) grouped summaries of slow requests (by
  method/path/controller/action), slow jobs (by job class/queue), slow
  phases (by phase/name/plugin-derived label), browser traces (by
  name/path, including nested API-request and span durations), and SQL
  fingerprints (deduplicated by a stable fingerprint, sample SQL attached).
  Each summary row carries count/total/average/max duration. When a prior
  app revision's data is available, `baseline.comparisons` diffs each
  current-revision row against its same-key baseline row and classifies it
  `regressed`/`improved`/`new`/`unchanged` (regressed: ≥250ms slower *and*
  ≥1.5x; improved: ≥250ms faster *and* ≤0.75x), letting operators spot
  regressions introduced by the latest deploy. `POST
  /api/v1/app/admin/performance/explain` runs `SyrusDev::SqlExplain`
  (below) from the same page for ad hoc query investigation.
- **Admin → Operational Logs** (`/admin/operational_logs`) — a search UI
  over `Admin::OperationalLogsPayload` (`GET
  /api/v1/app/admin/operational_logs`), the same indexed log search backing
  the `read_syrus_logs` MCP tool below. This page is hidden entirely from
  `AdminPages.admin_pages` when `OperationalLogging.enabled_for_instance?`
  is false, rather than rendered empty.

Both are mirrored at `/api/v1/admin/performance`,
`/api/v1/admin/performance/explain`, and `/api/v1/admin/operational_logs`
for the external Bearer-token admin API. Every action 404s with
`{ "error": "syrus_dev_plugin_disabled" }` when the plugin itself is
disabled.

## SQL Explain (`SyrusDev::SqlExplain`)

A guardrailed single-statement `EXPLAIN` runner, callable from the
Performance admin page and shared by no other surface:

- Accepts only `SELECT`/`WITH` statements; rejects multiple statements
  (`;`), inline comments (`/* */`, `--`, `#`), and any non-read-only keyword
  (`INSERT`/`UPDATE`/`DELETE`/`ALTER`/etc.) — even inside a plan, not just at
  the top level.
- On MySQL: default mode is `EXPLAIN FORMAT=JSON` (parsed into
  `json_plan`); `analyze: true` runs `EXPLAIN ANALYZE` instead (rejected if
  the statement contains `@`-prefixed user variables, since those aren't
  safe to actually execute), wrapped in a session `max_execution_time`
  (default 1000ms, capped at 5000ms) that's reset to unlimited afterward.
- On SQLite (dev/test): `EXPLAIN QUERY PLAN` only — `analyze: true` raises,
  since SQLite has no equivalent — with a warning that the plan can differ
  from production MySQL.
- `?` placeholders are substituted with literal `NULL` before explaining
  (`placeholder_substituted: true` flags this in the result) since the
  explain path has no bound parameter values to supply.

## MCP tools (`SyrusDev::WorkflowToolSet`)

Two tools, gated to Syrus-repository workflows
(`McpToolPolicy.syrus_repository?` — the Job's repository is
`tkadauke/syrus` or a registered fork) and to a role-scoped subset:

- `read_performance_diagnostics(limit?, revision_scope?, include_events?)` —
  only for `WORKFLOW_IMPLEMENT` agents. Returns the same summarized/baseline
  data as the admin page, run through an aggressive sanitizer before it ever
  reaches the agent: request/browser-trace `path`s have any segment that
  looks like a secret (`token`, `password`, `api_key`, etc., by key name or
  `key=value` pattern) replaced with `[REDACTED]`; SQL fingerprint rows
  drop `sample_sql` entirely (fingerprint text only); metadata keys/values
  and free-text fields are regex-scrubbed and byte-truncated. Raw individual
  `events` are included only when `include_events: true` is explicitly
  passed, and are sanitized the same way. Treat any diagnostics this tool
  returns as still process/command-shaped output — summarize findings to
  the operator rather than pasting raw fingerprints or paths verbatim, per
  the same convention as `read_run_worker_health`.
- `read_syrus_logs(query?, since?, level?, role?, hostname?, limit?)` — for
  both `WORKFLOW_IMPLEMENT` and `AGENT_INSIGHT` roles (the only tool in this
  plugin `agent_insight` runs can call). Thin wrapper over the core
  `OperationalLogSearch` service; returns a disabled-response payload
  instead of an error when `OperationalLogging.enabled_for_instance?` is
  false.

Both tools reject non-Syrus repositories and non-Syrus-development contexts
outright (`Mcp::Tools.not_authorized` / `.invalid`) rather than silently
returning empty data — a workflow on an unrelated customer repository never
sees these tools offered at all (`available_for_context?`/
`available_for?` filter them out of the manifest before a call could
happen).

## Operational notes

Several surfaces here expose Syrus's own internal implementation details
(request paths, job classes, SQL fingerprints, raw log lines) — useful for
agents actively working on Syrus's codebase, but not something to enable on
a general product installation where it would just be noise (and, for the
performance/log tools specifically, a narrower information-disclosure
surface than a typical admin plugin, since it's designed to hand runtime
internals to an *agent*, not just a human operator).
