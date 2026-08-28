# Worker Timeline

The `worker_timeline` plugin (`plugins/worker_timeline/`) visualizes
overlapping Syrus activity as a multi-lane timeline: one lane per worker
process (hostname+pid), with Job/Workflow spans over time. It is a
self-contained Rails engine plugin, installed but disabled by default
(`default_enabled: false`, `disableable: true`, category `observability`).
As with `mysql_db_browser`, the plugin's own `PluginRecord.enabled` toggle
*is* the feature gate — there is no separate `Feature` flag —
and `WorkerTimeline::SidebarPages#sidebar_pages` self-gates on both
`WorkerTimeline.enabled?` and `Current.user&.admin?`, returning `[]`
otherwise (the `sidebar_page` extension point itself has no per-page
visibility concept).

It covers both the **macro** (cross-job, multi-lane) view and a **micro**
per-workflow Step/Run waterfall drill-down (`/worker_timeline/workflow?id=<id>`,
reachable by clicking a macro-view Workflow span).

## Data sources

The plugin adds no new instrumentation. It reads:

- `WorkflowActivityEvent` / `SpawnedProcess` / `InstanceVersion` (worker
  attribution — see `Timeline::WorkerAttribution`).
- `Workflow`/`Step`/`Run` `started_at`/`finished_at` timestamps.
- `WorkUnits::StartBlock.explain` for the same blocked-reason explanation
  `Admin::StuckJobExplainer` uses — historical (already-resolved) spans may
  have no stored blocked-reason, and the API says so explicitly
  (`available: false`) rather than fabricating one. Shaping this into JSON
  (iso8601-encoding the Time fields) lives in `Timeline::BlockedExplanation`,
  shared by both query services below.

`app/services/timeline/macro_query.rb` (`Timeline::MacroQuery`) is the
underlying macro query service, and
`app/services/timeline/workflow_waterfall_query.rb`
(`Timeline::WorkflowWaterfallQuery`) the per-workflow one — both shared with
the bearer-token-gated `GET /api/v1/timeline/macro` and
`GET /api/v1/timeline/workflows/:id` endpoints meant for external admin API
clients. Steps have no blocked-reason machinery of their own (only
Workflows do), so `WorkflowWaterfallQuery` attaches the Workflow's own
blocked explanation to every not-yet-started Step payload — the same value
it puts on the top-level `workflow` payload — rather than fabricating a
per-Step reason.

## API

Because the plugin's frontend runs inside the authenticated browser SPA
(session-cookie auth), it cannot call the bearer-token `/api/v1/timeline/*`
endpoints directly. `Api::V1::App::Admin::WorkerTimelineController` (session
auth via `Api::V1::App::Admin::BaseController#require_admin`, plus its own
`require_worker_timeline_enabled` gate mirroring `mysql_db_browser`) wraps
the same query services for the browser:

- `GET /api/v1/app/admin/worker_timeline/macro` — `?from=&to=` (ISO8601,
  default last hour) plus `repository_id=`, `epic_id=`, `job_id=`,
  `hostname=`, `status=` (repeatable) filters.
- `GET /api/v1/app/admin/worker_timeline/workflow` — `?id=<workflow_id>`,
  the Step/Run waterfall for one Workflow (wraps
  `Timeline::WorkflowWaterfallQuery`).
- `GET /api/v1/app/admin/worker_timeline/filters` — filter option lists for
  the frontend's controls: `repositories`, `epics`, a fixed `statuses` list
  (`queued`/`running`/`succeeded`/`failed`/`cancelled`), and worker
  `hostnames` (from `InstanceVersion` rows with `role: "worker"`).

## Frontend

`/worker_timeline` (sidebar page `worker_timeline.macro`, icon `timeline`)
renders `WorkerTimeline.tsx`: hand-rolled React+SVG bars per span (no
charting library, consistent with `spending_insights`), `d3-scale` for the
time axis and `d3-zoom`/`d3-selection` for pan/zoom gesture handling, row
virtualization (only lanes within the current scroll viewport render their
span rects), and filter controls for repository/epic/status/worker
hostname plus a time-range picker. Hovering a span shows a tooltip with the
Job/Workflow id and title, duration, and the blocked-reason explanation (or
a plain "no historical data" message when none survives). Clicking a
Workflow span navigates to `/worker_timeline/workflow?id=<id>`.

That route renders `WorkflowWaterfall.tsx`: one lane per Step (in position
order), with that Step's Run attempt(s) drawn as spans within the lane so
retries are visible as sequential bars. It reuses the macro view's
rendering primitives (extracted under `components/timeline/`: the
`useZoomableTimeScale`/`useVirtualizedRows` hooks, `TimeAxis`, `TimelineBar`,
and the `formatDuration`/`blockedMessage` tooltip helpers) rather than
reimplementing bar rendering, pan/zoom, or tooltip logic. A Step with no
started Run yet renders as a hoverable "not started" marker instead of a
bar (there's no timestamp to place a bar at); its tooltip reuses the same
blocked-reason explanation the macro view shows for a pending Workflow. If
the Workflow itself hasn't started, the waterfall skips the time axis
entirely (there's no meaningful scale yet) and shows every Step as a
"not started" marker.
