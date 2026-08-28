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

This first release covers the **macro** (cross-job, multi-lane) view only.
A per-workflow Step/Run waterfall drill-down is a planned follow-up in the
same epic (EPIC-276); `/worker_timeline/workflow` currently renders a route
stub/placeholder rather than the real waterfall.

## Data sources

The plugin adds no new instrumentation. It reads:

- `WorkflowActivityEvent` / `SpawnedProcess` / `InstanceVersion` (worker
  attribution — see `Timeline::WorkerAttribution`).
- `Workflow`/`Step`/`Run` `started_at`/`finished_at` timestamps.
- `WorkUnits::StartBlock.explain` for the same blocked-reason explanation
  `Admin::StuckJobExplainer` uses — historical (already-resolved) spans may
  have no stored blocked-reason, and the API says so explicitly
  (`available: false`) rather than fabricating one.

`app/services/timeline/macro_query.rb` (`Timeline::MacroQuery`) is the
underlying query service, shared with the bearer-token-gated
`GET /api/v1/timeline/macro` endpoint meant for external admin API clients.

## API

Because the plugin's frontend runs inside the authenticated browser SPA
(session-cookie auth), it cannot call the bearer-token `/api/v1/timeline/*`
endpoints directly. `Api::V1::App::Admin::WorkerTimelineController` (session
auth via `Api::V1::App::Admin::BaseController#require_admin`, plus its own
`require_worker_timeline_enabled` gate mirroring `mysql_db_browser`) wraps
the same `Timeline::MacroQuery` for the browser:

- `GET /api/v1/app/admin/worker_timeline/macro` — `?from=&to=` (ISO8601,
  default last hour) plus `repository_id=`, `epic_id=`, `job_id=`,
  `hostname=`, `status=` (repeatable) filters.
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
Workflow span navigates to `/worker_timeline/workflow?id=<id>`, the
waterfall drill-down stub.
