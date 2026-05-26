# Admin diagnostics — investigation tooling

Built up after a series of production debugging sessions where the
common loop was "write a Rails runner script → `kubectl cp` it in
→ `kubectl exec bin/rails runner` → parse the output → form a
hypothesis." The slow part wasn't the queries; it was the shell
round-trip and the per-incident scriptwriting.

This doc captures the diagnostic features that would have shortcut
the recent debugs. Tiered by leverage. Implementation starts at
the top.

## Patterns we kept hitting

| Investigation | Question | What we did | What would've been faster |
|---|---|---|---|
| Job 26 / 28 (max_turns) | "What did the agent actually do in 6 turns?" | Wrote runner script, dumped JSONL, parsed tool calls by hand | Click through to a transcript view |
| Job 65 (stuck running) | "Why isn't the reaper picking this up?" | Queried `SolidQueue::Job` + ran reaper manually | Queue inspector showing pending recurring jobs |
| Mergeability check broken | "Did the poll job actually run? Did GH return 304?" | Inferred from `pr_mergeable_checked_at` not moving | Per-Job timeline / GH API call log |
| Provider transcript capture failing | "Are transcripts ever being captured?" | Queried transcript storage — went looking for the bug | System overview with a "transcript capture rate" tile |
| MCP tools missing | "Was `submit_summary` registered when implement started?" | Dug through JSONL for the system init event | Transcript view that surfaces session init events |

The thread: each debug needed answers to "what's the hidden state
right now?" — disk, queue tables, claude session JSONL, MCP tool
list. Surfacing those once means we don't recompute them per
incident.

---

## Top-tier (build first)

These cover the bulk of the investigation cost. Build as a unit —
shared admin namespace, shared layout, shared table components.

### A. Full transcript viewer per Run

**Why:** Jobs 26 and 28 took hours each, both because the JSONL
inspection was manual. A rendered view would have answered both
in seconds.

**Shape:**

- New admin route: `/admin/runs/:id/transcript`
- Linked from the existing per-Run diagnostic panel (admin-only)
- Source: `Run#claude_session.transcript_jsonl`
- Render the JSONL events in chronological order:
  - **System init** — model name, working directory, list of
    available tools (CRITICAL — answers "was the MCP tool
    registered?" without grepping)
  - **User turns** — the prompt content (truncated/expandable)
  - **Assistant turns** — text content + each tool_use as a
    nested card (tool name, inputs as JSON, result, duration)
  - **Tool results** — collapsed by default, click to expand
  - **Result event** — final summary (turns, cost_usd, exit
    reason)
- Search box that filters events by keyword across all content
- "Download as JSONL" button for offline analysis
- Sticky summary bar at top: total turns, total tool calls, total
  cost, exit reason, was MCP tool called?

**Tricky bits:**

- The JSONL is `MEDIUMTEXT` and can be hundreds of KB to a few
  MB. Stream-parse server-side rather than dumping the whole
  thing into the page; Turbo Frame per page of events for
  pagination.
- Some events have nested arrays of content blocks. Renderer
  needs to handle text + tool_use + tool_result + thinking in
  the same `content` array.

### B. Queue inspector

**Why:** Job 65's starvation was a one-look bug if you can see
the queue. We can't today.

**Shape:**

- New admin route: `/admin/queue`
- Tabs: **Active** (claimed/running) | **Pending** (queued) |
  **Failed** (last 24h) | **Recurring** | **Workers**
- Active / Pending / Failed: table of `SolidQueue::Job` filtered
  to the tab, columns: id, class_name, queue, arguments
  (truncated), enqueued at, claimed by (worker pid), age in queue
- Failed tab: also shows `failed_execution.error.exception_class`
  and message; "Retry" button (re-enqueues a fresh execution);
  "Discard" button
- Recurring tab: each entry from `config/recurring.yml` with
  schedule + last fired at + next due at. Color-code red when
  "haven't fired in N expected intervals."
- Workers tab: `SolidQueue::Process` rows — pid, hostname, queues,
  threads, last heartbeat. Color-code red when heartbeat is stale.
- Per-row "Reap pruned workers now" button at the top of the
  Workers tab (same as `ReapStaleRunsJob.perform_now`).

**Tricky bits:**

- SolidQueue tables aren't in the dev/test connection — wrap
  every query in `ActiveRecord::StatementInvalid` rescue and show
  a friendly "queue tables unreachable from this connection" in
  dev. Same pattern as `ReapStaleRunsJob#pruned_run_ids_from_solid_queue`.
- Argument deserialization can be heavy for large payloads
  (Workflow artifacts, prompt strings). Truncate to first 200
  chars in the table; expand on click.

### F. System overview page

**Why:** "Is anything wrong?" should be answerable in one
glance without opening kubectl. Today the answer is "go check
five places."

**Shape:**

- New admin route: `/admin` (dashboard for admins)
- Single page, grid of tiles, each linking to a deeper view:
  - **Active runs** — count of `Run` in `running` state, broken
    out by trigger_kind. Click → /admin/queue
  - **Queued runs** — count by queue (`runs` vs `default`).
    Click → /admin/queue
  - **Worker heartbeats** — N workers up, last heartbeat ages.
    Red tile if any stale.
  - **Recurring jobs health** — green if all recurring jobs
    fired within their expected interval × 2; red if any are
    overdue.
  - **Recent failures** — count of `Run` failed in last hour /
    24h. Click → list.
  - **GitHub rate limits** — per-user, current / total. Red if
    any user is below 10%.
  - **Provider transcript capture rate** — % of agentic Runs in last
    24h that have a captured provider transcript. Red if < 80% (the
    canonical-path bug would have shown 0% here).
  - **Stuck workflows watchlist** — workflows in `running` state
    older than the median, queued runs older than the median,
    failed workflows nearing prune (cleaned_up_at nil + finished
    >5 days ago), workspaces on disk for terminal workflows.

**Tricky bits:**

- "Disk presence" check for the workspace tile needs the worker
  pod (web pod doesn't mount the data PVC). Defer for now —
  trust `cleaned_up_at`. Or expose via a small RPC if it
  becomes important.
- Tiles need to be cached / incrementally updated; a full
  recompute on every page load is wasteful when the operator is
  refreshing repeatedly.

---

## Mid-tier (build after top-tier lands real value)

### I. Per-Job event timeline

Single chronological feed merging Workflow + Step + Run state
transitions, JobLog chunks, GitHub side effects (PR opened,
comments received, CI failures), mergeability rechecks. Replaces
the "scroll between three tables to reconstruct narrative"
pattern that came up in the Job 26 / 28 investigations.

Embed under Job#show as a new collapsible block above the
workflow cards. Each event = one row with timestamp, source
(workflow / step / run / github / poller), and a one-line
description.

### G. "Stuck things" watchlist

Auto-detect:

- Runs in `running` state with stale heartbeats (would have
  surfaced Job 65's pre-reap state).
- Failed workflows with `cleaned_up_at` nil whose `finished_at`
  is older than `WorkflowWorkspacePruneJob::RETAIN_AFTER_TERMINAL`
  minus a day (about to be pruned — last chance to retry).
- Recurring jobs whose last `finished_at` is older than 2× their
  expected interval (would have screamed about Job 65's reaper).
- Workflows whose `cleaned_up_at` is set but whose disk
  workspace still exists (silent cleanup failure — needs PVC
  introspection).
- Workflows whose `cleaned_up_at` is nil but whose disk workspace
  is gone (PVC eviction or manual delete — same).

Surface as a tile on the overview page (F) AND a dedicated
`/admin/stuck` view that lists each anomaly with a "what to do"
hint and a one-click fix where possible.

### L. Operator console / kill switches

`AppSetting`-backed runtime levers:

- Pause all polling (toggles `polling_enabled` to false on every
  Repository, or a global flag the polling jobs check first).
- Pause new RunJobs (existing ones drain; new enqueues are held
  in a `paused` state).
- Bump `agent_max_turns` globally.
- Adjust `max_job_failures`.
- Force-reap all stale runs (one-click `ReapStaleRunsJob.perform_now`).
- Clear `GithubClient` cache (per-user or all).

Each control is one button + a confirm. Logs the action with
operator + timestamp to a small `AdminAction` table for after-
the-fact accountability.

---

## Lower-tier (situational, defer)

### C. Workspace inspector

Per-Workflow: disk size, `cleaned_up_at`, "is the workspace dir
on disk right now?" Useful when retry-from-failed-step doesn't
behave as expected. Needs PVC introspection — small RPC from
web pod to a worker pod, or expose a worker-side endpoint.

### E. GitHub API call log

Last N calls per user with status / duration / cache-hit / URL,
plus a per-user rate-limit timeseries. Would help when
investigating cache-related issues (the conditional GET 304
behavior). Not high enough leverage to justify the
instrumentation cost on every call.

### K. Per-Step "what did the agent do" summary

Auto-extracted from the transcript: counts of tool calls per
tool, files read/edited, commands run, whether MCP tools were
invoked. Shown inline on the Step row as a compact summary
("47 Bash, 5 Read, 3 Edit · submit_summary called"). Saves
opening the transcript for the common "did anything weird
happen?" question. Build after A — depends on the same parsing
logic.

---

## Things to skip

- **Diagnostic dump button** — A renders the same data
  interactively. Tarball-then-parse is worse than just looking at
  the rendered view.
- **MCP tool registration verifier as standalone feature** — the
  system init event in A's transcript view shows the tool list
  directly. No need for a parallel UI.
- **Provider transcript inspector as standalone** — A subsumes it.

---

## Build order

1. **A — transcript viewer** (own admin namespace, JSONL parser,
   first table component). Largest leverage; biggest visible
   improvement.
2. **B — queue inspector** (reuses admin namespace + table
   component). Catches the SQ-shaped class of bugs.
3. **F — system overview** (assembles tiles that link into A and
   B). Front door for "is anything wrong?"
4. Pause, use the system, see what's still painful.
5. **I → G → L** in that order if still warranted.

Admin gating: existing `Current.user&.admin?` check (already
used by RunDiagnostic in `_step.html.erb`). New routes scoped to
admins via a `before_action :require_admin`.

---

## REST API + Claude skill (so the agent can self-debug)

The whole point of these tools is to shortcut investigation. The
human in the loop benefits from the UI; **Claude (running in the
operator's terminal) benefits from a structured API + a skill
that documents how to use it.** The kubectl-cp + Rails-runner loop
that was painful for me-the-human is also painful for Claude —
it has to write the script, copy it in, exec it, parse the
output. A versioned JSON API replaces all of that with a single
`curl`.

### Shape

- New namespace: `/api/v1/admin/*`. Same `require_admin` gate
  as the HTML admin views, but with an additional auth path
  (token-based, per-user) so the API can be called from outside
  a browser session. Token lives on `User#api_token` (encrypted,
  rotatable from /credentials).
- Response shape: `application/json` always; errors as
  `{ "error": { "code": "...", "message": "..." } }` with proper
  HTTP status. No HTML in the API.
- Versioned at v1. Breaking changes get a v2; no rolling
  changes within v1.
- Auth via `Authorization: Bearer <token>` header.

### Endpoints (v1)

Mirroring the admin UI, but JSON-shaped for programmatic use:

**Transcripts (A)**
- `GET /api/v1/admin/runs/:run_id/transcript` →
  `{ summary: {...}, events: [...] }` (paginated for large
  sessions via `?page=N&per=50`)
- `GET /api/v1/admin/runs/:run_id/transcript/raw` → raw JSONL,
  same as the download endpoint

**Queue (B)**
- `GET /api/v1/admin/queue/active` → currently-claimed SQ jobs
- `GET /api/v1/admin/queue/pending` → queued, not yet claimed
- `GET /api/v1/admin/queue/failed?since=ISO8601` → recent failures
- `GET /api/v1/admin/queue/recurring` → schedule + last-fired-at
- `GET /api/v1/admin/queue/workers` → process list + heartbeats
- `POST /api/v1/admin/queue/reap_stale_runs` → trigger
  `ReapStaleRunsJob.perform_now`

**Overview (F)**
- `GET /api/v1/admin/overview` → all the tiles' data in one shot
- `GET /api/v1/admin/stuck` → the watchlist (G)

**Job introspection (general)**
- `GET /api/v1/admin/jobs/:id` → Job + Workflows + Steps + Runs
  + diagnostics + claude_session metadata, all in one shot.
  Replaces the "dump full state" Rails runner pattern from
  every recent investigation.
- `GET /api/v1/admin/runs/:id/diagnostic` → RunDiagnostic JSON

**Workflow control**
- `POST /api/v1/admin/workflows/:id/retry_step` → mirror of the
  existing JobsController#retry_step
- `POST /api/v1/admin/workflows/:id/cleanup_workspace` →
  trigger `WorkflowWorkspace.cleanup_for(workflow)` early
  (handy when the operator wants to free disk before the daily
  prune)

### Claude skill

Lives at `~/.claude/skills/syrus-debug/SKILL.md` (per-user) or in
the project's `claude-skills/` directory if we want it
checked-in. The skill documents:

- Auth setup (where to put the API token; one-line `curl` template)
- Decision tree per investigation type:
  - "Job seems stuck" → check `/admin/jobs/:id`, then
    `/admin/queue/workers` + `/admin/queue/recurring`
  - "Run failed with max_turns" → fetch transcript, look at
    `summary.tool_call_counts` and `summary.mcp_tool_called?`
  - "Mergeability not updating" → fetch the Job + check
    `pr_mergeable_checked_at`, then `/admin/queue/failed` for
    PollRebaseJob errors
- A short list of "if you see X, look at Y" patterns drawn from
  this doc's "Patterns we kept hitting" table
- Safe-to-call vs careful-with endpoints (POST mutations are
  the ones that need explicit user authorization)

The skill's load-on-demand model means Claude reads it only when
debugging Syrus, so it doesn't inflate the per-session context.
The skill itself can `curl` the API directly; no special Claude
tooling required.

### Build order amendment

After A / B / F land their UI, expose the same data through the
v1 API in one batch. The HTML controllers and the API
controllers share the same data assembly methods (extract a
small `Diagnostics::*` namespace of plain Ruby objects that
returns hashes, then both controllers serialize). Skill ships
with the API.
