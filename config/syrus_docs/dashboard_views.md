# Dashboard Views

The Jobs and Epics dashboards support three view modes toggled from the toolbar:

## list

Default tabular view. Supports column visibility, sorting, and pagination. Columns are configurable per-user per-subject. The Jobs dashboard includes an optional `deployment` column, hidden by default, that shows the furthest configured deployment stage a Job has reached.

## kanban

Board view grouped by configurable lanes (e.g. Queued, Running, Succeeded). Lanes are configurable per-user per-subject and available for Jobs, Epics, and Workflows.

Kanban payloads are paginated per lane. Each lane includes `total_count`, `loaded_count`, `has_more`, and `next_offset`; when `has_more` is true, the UI shows a lane-specific Load more button. Follow-up lane fetches call `GET /api/v1/app/dashboard` with the existing dashboard filters plus `kanban_lane` and `kanban_offset`, so loading older cards preserves the current smart folder, ownership scope, and other lane state.

Queued Job cards can carry a start-blocked badge when Syrus has deferred the first Run because dependencies are unfinished, a dependency failed or was cancelled, the Job/Epic is not ready for execution, main is broken, or an urgent Job is active. The Queued smart folder also shows a blocked sub-count; selecting that count filters to only queued Jobs with a persisted start-blocked reason.

## dependencies

Topological dependency graph showing jobs (or epics) as nodes and their `Depends-on` / `Blocked-by` relationships as directed edges. Nodes are placed in columns by dependency depth: Layer 0 has no blockers, Layer N is blocked by Layer N-1 work. Clicking a node navigates to the job or epic detail page.

Not available on the Workflows dashboard. The Dependencies tab is also hidden on mobile dashboards because the graph view is desktop-only; if a persisted mobile URL still requests `view=dependencies`, the page shows an unavailable message instead of loading the graph.

## Bulk retry

The Jobs dashboard bulk `Retry` action uses `SmartRetryEnqueuer`, not a blind
implementation retry. For each selected Job it chooses the narrowest safe
action: resume a failed agentic step when a resumable session exists, retry the
failed step while the workflow workspace is available, retry or rebuild landing
workflows for landing failures, and only fall back to a full
`Workflows::Retry` implementation retry when narrower recovery is unavailable.

Bulk retry skips closed Jobs, approved Jobs, no-change-needed Jobs, Jobs whose
open PR is already current with base and passing checks, Jobs with active Runs,
Jobs with an active queued/running retry Workflow, and automatic retries blocked
by the provider circuit breaker. The API response includes
`retry_summary.actions` and `retry_summary.skipped` buckets so operators can see
how many Jobs took each path.

The explicit Job detail `Retry implementation` action remains available for
operators who intentionally want a full implementation retry.

**Empty states:**
- If the active filter matches no jobs/epics, the view shows "No [subject] match this view."
- If nodes are present but none have dependency edges between them (all at Layer 0), the view shows "No dependency relationships in the current view."

**Data source:** `GET /api/v1/app/jobs/graph` and `GET /api/v1/app/epics/graph`. Both endpoints accept the same filter params as the corresponding index endpoints (`repo`, `state`, `q`, `smart_folder_id`) and return `{ nodes, edges }` scoped to `accessible_to(Current.user)`.

## View preference persistence

The selected view is persisted per `[subject, smart_folder_id]` pair and restored on next load. Preferences are stored via `User#update_dashboard_folder_preferences!` and resolved by `DashboardPayload#folder_pref_view`. All three view values (`list`, `kanban`, `dependencies`) are valid persisted values.
