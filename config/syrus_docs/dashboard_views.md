# Dashboard Views

The Jobs and Epics dashboards support three view modes toggled from the toolbar:

## list

Default tabular view. Supports column visibility, sorting, and pagination. Columns are configurable per-user per-subject. The Jobs dashboard includes an optional `deployment` column, hidden by default, that shows the furthest configured deployment stage a Job has reached.

## kanban

Board view grouped by configurable lanes (e.g. Queued, Running, Succeeded). Lanes are configurable per-user per-subject and available for Jobs, Epics, and Workflows.

Kanban payloads are paginated per lane. Each lane includes `total_count`, `loaded_count`, `has_more`, and `next_offset`; when `has_more` is true, the UI shows a lane-specific Load more button. Follow-up lane fetches call `GET /api/v1/app/dashboard` with the existing dashboard filters plus `kanban_lane` and `kanban_offset`, so loading older cards preserves the current smart folder, ownership scope, and other lane state.

Queued Job cards can carry a start-blocked badge when Syrus has deferred the first Run because dependencies are unfinished, a dependency failed or was cancelled, the Job/Epic is not ready for execution, main is broken, an urgent Job is active, provider availability is below the user's per-agent threshold, or workflow admission budgeting delayed the start. The Queued smart folder also shows a blocked sub-count; selecting that count filters to only queued Jobs with a persisted start-blocked reason.

When the blocked reason is workflow admission budgeting, the Workflow artifact stores the admission decision payload. The payload separates predicted command cost from current host headroom: command-attributed step profiles are used when they have enough samples, host-correlated profiles are included as fallback/context, and live worker host pressure is still checked immediately before starting work. The details also record attribution confidence, fallback reasons, active run/repository counts, Job priority, and whether the delay was caused by ambient host pressure or by predicted command cost not fitting the budget.

After Solid Queue assigns a queued Run to a concrete compute worker,
`RunJob` also performs a host-local pickup check. If the selected worker is
critically pressured or already running resource-guarded agentic/grader work,
the Run remains queued and is re-enqueued without spending a retry iteration.
Those deferrals record `run_host_admission` on the Workflow artifact and a
system JobLog line rather than `start_blocked_details`, because the Workflow
was not phase-blocked by the dispatcher.

Manual Job pause is different from admission/resource pauses: it is a persistent
Job flag set by an operator. Pausing a Job does not kill the current Run. Syrus
lets the active Step finish, then records `pause_reason: manual_pause` on the
active Workflow and stops before creating the next Run. A manually paused Job
stays paused until an operator unpauses it; scheduled rechecks and admission
wakeups do not override it. Unpause clears the manual Workflow pause marker and
asks the normal dispatcher or landing queue to resume, so the Job still remains
subject to dependency gates, provider circuits, and workflow admission control.
The dashboard includes manually paused Jobs in the Paused smart folder and
shows a direct Unpause control on paused rows.

Provider-availability pauses are automatic and reversible. Each user has a
per-agent pause threshold in Agent Settings; the default is 10%, and 0 disables
automatic provider-availability pauses for that provider. When Codex usage falls
below the configured threshold, or a configured provider reports exhausted usage,
Syrus records `pause_reason: provider_availability` /
`start_blocked_reason: provider_availability` on the active Workflow and stops
before creating the next Run. Running steps are allowed to finish. A scheduled
recheck wakes the Workflow after the provider reset or a short probe interval;
for Codex, the wakeup refreshes the structured usage snapshot before deciding
whether to resume. The usage banner and Agent Settings both expose "Recheck" and
"Resume anyway"; the latter stores a per-user/provider override that suppresses
provider-availability pauses until newer provider evidence arrives.

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
