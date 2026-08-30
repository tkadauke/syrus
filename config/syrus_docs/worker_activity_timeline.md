# Worker Activity Timeline Data API

Read-only backend data API for a multi-lane worker activity timeline: one
lane per durable worker process role (`worker_storage_key` + `queue_role`)
with Job/Workflow spans over time (macro view), plus a per-Workflow
drill-down of Steps/Runs (micro/waterfall view). `hostname` and `pid` remain
point-in-time attributes on spans so callers can show where work ran and
detect process restarts within a durable lane.

The only timeline-specific instrumentation is the `queue_role` captured on
`WorkflowActivityEvent` for `RunJob` executions. The queries otherwise read
from data Syrus already collects: `Workflow`/`Step`/`Run` timestamps,
`WorkflowActivityEvent` (see `config/syrus_docs/observability.md`),
`SpawnedProcess`, and `InstanceVersion`. There is no thread-slot allocator
or per-thread concurrency instrumentation; overlapping spans inside a lane
are packed by the frontend from timestamps.

## Endpoints

Gated the same way as the rest of the token-based REST admin API
(`Authorization: Bearer <api_token>`, `User#admin?` required) by
`Api::V1::Timeline::BaseController < Api::V1::Admin::BaseController`.

- `GET /api/v1/timeline/macro` — `Timeline::MacroQuery`. Params:
  `from`/`to` (ISO8601; default window is the last hour),
  `repository_id`, `epic_id`, `job_id`, `hostname`, `status` (Workflow
  state; accepts a comma-separated list). Returns:
  - `lanes`: grouped by durable lane identity when available. Each lane has
    `key`, `worker_storage_key`, `queue_role`, representative `hostname` and
    `pid`, `instance` (the matching `InstanceVersion` row, when found), and
    `spans` — one per Workflow overlapping the range. A span carries
    `worker_storage_key`, `queue_role`, `hostname`, `pid`, `workflow_id`,
    `job_id`, `started_at`, `finished_at`, `status`, `label`, and `blocked`
    (see below). Events that predate `queue_role` or lack
    `worker_storage_key` fall back to legacy `hostname` + `pid` lane keys. A
    worker whose `InstanceVersion` overlaps the range but produced no
    attributable spans still gets an empty-`spans` lane, so idle periods are
    visible rather than the worker silently disappearing from the chart.
  - `pending`: Workflows that haven't started yet (so they have no lane to
    place a span in) — `workflow_id`, `job_id`, `label`, `created_at`,
    `blocked`.
- `GET /api/v1/timeline/workflows/:id` — `Timeline::WorkflowWaterfallQuery`.
  Returns the target Workflow (with resolved `worker_storage_key`,
  `queue_role`, `hostname`, and `pid`) plus its Steps, in order, each
  carrying the same worker attribution (Step/Run have no host column of
  their own) and its Runs (`started_at`, `finished_at`, `last_heartbeat_at`).

## Worker attribution

`Timeline::WorkerAttribution` resolves the worker attribution a Workflow ran
on, in one fallback chain shared by both queries:

1. The earliest `workflow_started`/`run_started` `WorkflowActivityEvent` row
   tied to the Workflow — the most precise source, since it carries the
   `queue_role` and actual `Process.pid` recorded at the moment of that
   state transition. `worker_storage_key` comes from the Workflow row.
2. An attributed `SpawnedProcess` row for the Workflow — covers Workflows
   outside `WorkflowActivityEvent`'s 14-day retention window. It supplies
   `hostname`/`pid`; `worker_storage_key` still comes from the Workflow, and
   `queue_role` is nil.
3. `Workflow#worker_hostname` alone (hostname only, `pid: nil`,
   `queue_role: nil`) — the last resort, when neither event source survives.

`Timeline::MacroQuery` uses `worker_storage_key` + `queue_role` as the lane
key only when both values are present. Otherwise it keeps the legacy
`hostname` + `pid` lane key so pre-migration rows and non-`RunJob` activity
degrade gracefully instead of being collapsed into ambiguous durable lanes.

## Blocked-reason reuse

`blocked` on both spans and pending entries comes from
`WorkUnits::StartBlock#explanation` (`WorkUnits::StartBlock.explain(workflow)`),
the same blocked-reason source `Admin::StuckJobExplainer` uses for a Job's
`workflows` payload — the WorkUnit/admission-block lookup lives in exactly
one place, not duplicated between the admin explainer and this API.

The response shape is `{ blocked_reason, blocked_since, blocked_details,
next_check_at, available, historical }`. `WorkflowActivityEvent` has no
stored history of blocked-reason *transitions* — only point-in-time
started/finished events — so this never tries to reconstruct a historical
block reason from the activity stream. `available: false` is the honest
answer once a block has been superseded (the `WorkUnit` unblocked, or a
terminal Workflow never wrote a `start_blocked_*` artifact): "no record
survives", not a guess. `historical: true` marks that the owning Workflow
has already finished, for callers that want to distinguish "this is why
it's stuck right now" from "this is what the last recorded block on this
finished Workflow was, if any."
