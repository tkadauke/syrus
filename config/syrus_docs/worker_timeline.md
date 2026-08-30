# Worker Timeline

The `worker_timeline` plugin (`plugins/worker_timeline/`) visualizes
overlapping Syrus activity as a multi-lane timeline: one lane per durable
worker process role (`worker_storage_key` + `queue_role`), with Job/Workflow
spans over time. It is a
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

The plugin reads:

- `WorkflowActivityEvent` / `SpawnedProcess` / `InstanceVersion` (worker
  attribution — see `Timeline::WorkerAttribution`).
- `Workflow`/`Step`/`Run` `started_at`/`finished_at` timestamps.
- `WorkUnits::StartBlock.explain` for the same blocked-reason explanation
  `Admin::StuckJobExplainer` uses — historical (already-resolved) spans may
  have no stored blocked-reason, and the API says so explicitly
  (`available: false`) rather than fabricating one. Shaping this into JSON
  (iso8601-encoding the Time fields) lives in `Timeline::BlockedExplanation`,
  shared by both query services below.

`WorkflowActivityEvent` now captures `queue_role` for `RunJob` executions,
which lets the macro query distinguish separate worker processes that share
one storage volume, such as `runs` and `merges`. `Workflow#worker_storage_key`
provides the durable storage/pod identity. `hostname` and `pid` stay on each
span as point-in-time attributes for tooltips and restart markers, but they
are no longer the primary lane key when both durable fields are available.
Rows that predate `queue_role`, lack `worker_storage_key`, or come from
non-`RunJob` activity still fall back to legacy `hostname` + `pid` lane
grouping. The backend does not allocate per-thread slots; the frontend packs
overlapping spans inside a lane from timestamps.

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

- `GET /api/v1/app/admin/worker_timeline/macro` — `?q=<base64-encoded
  filter tree>`, the same wire format the app-wide shared FilterBar
  (`app/frontend/components/FilterBar.tsx`) uses everywhere else
  (`Filters::QueryParam`/`Filters::Ast`). `Timeline::MacroQueryFilter`
  decodes `q` into the `repository_id`/`epic_id`/`hostname`/`status`/
  `from`/`to` arguments `Timeline::MacroQuery` accepts, and exposes a
  registry-backed `filter_schema` for the `worker_timeline` subject:
  `repository_id`/`epic_id`/`hostname` as `fk` (typeahead) fields backed by the existing
  `/api/v1/app/filters/fk_options` resolver (`Filters::FkOptionsResolver`
  serves `repository_id`/`epic_id` unscoped — every repository/epic in
  the instance, not just ones the signed-in admin owns — when the current
  user is an admin, since this is a cross-tenant admin view and every
  visitor is admin-gated already; non-admin callers elsewhere in the app
  keep the ownership-scoped relation), `status` as a multi-select
  `enum`, and a `window` `date` field supporting `within_last` (relative)
  and `between` (absolute) — no `q` (no chips at all) defaults to
  `within_last` the last 3 hours with no other filters applied, i.e. every
  worker lane and every workflow in that window. The response echoes back
  `filter` (the applied tree) and `filter_schema` alongside `range`/
  `lanes`/`pending`. Each lane includes `key`, `worker_storage_key`,
  `queue_role`, representative `hostname`/`pid`, `instance`, and `spans`;
  each span includes its own `worker_storage_key`, `queue_role`,
  `hostname`, and `pid` along with Workflow timing/status fields.
- `GET /api/v1/app/admin/worker_timeline/workflow` — `?id=<workflow_id>`,
  the Step/Run waterfall for one Workflow (wraps
  `Timeline::WorkflowWaterfallQuery`). The workflow and each Step payload
  include the resolved `worker_storage_key`, `queue_role`, `hostname`, and
  `pid`.

`worker_timeline` is a `Filters::Registry` subject so shared FilterBar
schema serialization, top-level suggestion search, and filter-usage
recording can use the same infrastructure as Dashboard/Search. The macro
query still does not compile arbitrary registry chips into one relation:
`Timeline::MacroQuery` isn't a single AR relation a `Filters::Compiler`
chip can `.where` against (spans come from `Workflow`, pending from a
second `Workflow` scope, idle lanes from `InstanceVersion`, and the time
window is an overlap test applied across all three, not a plain column
comparison), so `Timeline::MacroQueryFilter` only understands a flat
top-level AND of chips — the shape the FilterBar produces for this small,
fixed field set. Worker timeline does not currently expose SmartFolders;
its registry subject exists for filter metadata and suggestions, not
saved-folder navigation.
The separate bearer-token `GET /api/v1/timeline/macro` endpoint (see
`config/syrus_docs/worker_activity_timeline.md`) is untouched by this and
keeps its own flat `repository_id=`/`epic_id=`/`job_id=`/`hostname=`/
`status=`/`from=`/`to=` params and 1-hour default.

## Frontend

`/worker_timeline` (sidebar page `worker_timeline.macro`, icon `timeline`)
renders `WorkerTimeline.tsx`: hand-rolled React+SVG bars per span (no
charting library, consistent with `spending_insights`), `d3-scale` for the
time axis and `d3-zoom`/`d3-selection` for pan/zoom gesture handling, row
virtualization (only lanes within the current scroll viewport render their
span rects), and the app-wide shared `FilterBar` (same component and
query-tree wiring as `AdminQueue`/`AdminUsers`/`Dashboard`) for repository/
epic/hostname/status/time-window filtering — the plugin no longer ships its
own filter UI. Hovering a span shows a tooltip with the
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

The macro view wires `FilterBar`'s `suggestionSearch` to
`surface: "worker_timeline", subject: "worker_timeline"` and records
applied filters through `/api/v1/app/filters/usage` on the same
surface/subject. Typing free text in the add-filter search before choosing a
field therefore offers one-click top-level suggested chips for matching
repositories, epics, and worker hostnames (for example, "Repository is
tkadauke/syrus") in addition to the per-field typeahead that appears inside
an already-added FK chip.
