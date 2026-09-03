# Dashboard Views

The Jobs and Epics dashboards support three view modes toggled from the toolbar:

## list

Default tabular view. Supports column visibility, sorting, and pagination. Columns are configurable per-user per-subject. The Jobs dashboard includes an optional `deployment` column, hidden by default, that shows the furthest configured deployment stage a Job has reached.

## kanban

Board view grouped by configurable lanes (e.g. Backlog, Queued, Running, Succeeded). Lanes are configurable per-user per-subject and available for Jobs, Epics, and Workflows. Backlogged Jobs are open planned work, but they do not dispatch Workflows or Runs until an operator releases them from backlog.

Kanban payloads are paginated per lane. Each lane includes `total_count`, `loaded_count`, `has_more`, and `next_offset`; when `has_more` is true, the UI shows a lane-specific Load more button. Follow-up lane fetches call `GET /api/v1/app/dashboard` with the existing dashboard filters plus `kanban_lane` and `kanban_offset`, so loading older cards preserves the current smart folder, ownership scope, and other lane state.

## Backlogged Job actions

Backlogged Jobs follow the same ownership model as backlogged Epics: the durable owner is `Job#owner_user_id` (or the effective owner derived by existing ownership scopes). The legacy `claimed_by_user_id` fields remain a short-lived work-claim overlay only. Operator UI and API payloads should label claim actions as work claims so they are not confused with owner assignment.

Single-Job lifecycle endpoints:

- `POST /api/v1/app/jobs/:job_id/release_from_backlog` releases a backlogged Job into the normal admission flow. A valid, dependency-ready Job transitions to `queued` and creates initial Workflow work through the same path as post-triage startup. A dependency-blocked Job transitions to `blocked_by_epic` without starting a Run. A Job that still needs classifier/triage resolution moves to `triaging`.
- `POST /api/v1/app/jobs/:job_id/move_to_backlog` moves only early, pre-runtime Jobs (`needs_triage`, `triaging`, `blocked_by_epic`, or `queued`) back to backlog. The guard rejects Jobs with queued/running Workflows, active Runs, local PRs, fork-review PRs, external PRs, review/landing states, and any post-PR work.
- `PATCH /api/v1/app/jobs/:job_id/owner` assigns or reassigns `owner_user_id`. The selected owner must be a repository member with read access. This does not claim the Job for active work.
- `POST /api/v1/app/jobs/:job_id/claim` and `DELETE /api/v1/app/jobs/:job_id/claim` operate only on the work-claim overlay. A Job claimed by another user cannot be claimed, and only the current claimant can release their claim.

The Jobs dashboard bulk toolbar mirrors the single-Job management surface where bulk semantics are already supported: release/start from backlog, move to backlog, assign owner, set priority, add/remove tags, claim work, and release claim. Bulk actions are permission-checked per selected Job, so repository membership and write-policy failures skip only the affected rows. Responses include affected IDs plus skipped IDs/counts, allowing the UI to report partial success instead of treating one rejected Job as a failed batch. There is no bulk proposal-routing action; routing a proposed direct Job to backlog stays on the individual proposal card before confirmation.

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

Agent Settings also stores the user-level agent-provider failover policy for
future workflow admission paths. The policy is disabled by default, contains an
ordered list of candidate agent providers, and only selects from
`User#configured_agent_providers`. Its cause list distinguishes usage
exhausted, low usage, rate limits, transient provider/circuit-open failures,
and auth errors; auth errors are represented but are not in the default
automatic-failover cause set. Explicit Job provider settings are respected by
default unless the separately named explicit-pin override is enabled. Chat
provider switching remains explicit and is not driven by this policy.

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

## Shared FilterBar primitives

FilterBar-backed surfaces use `Filters::Schema` metadata to expose reusable
filter behavior instead of per-page search boxes. Text chips can opt in to
typed-query suggestions with `full_text_suggestions`; when the add-filter menu
has at least two typed characters, `/api/v1/app/filters/suggestions` can
synthesize ordinary AST chip nodes such as `{ "field": "title", "op":
"matches", "value": "queue" }`. These suggestions work in the same `q=`
base64url filter tree as manually added chips and can be saved in
SmartFolders.

The `matches` operator is separate from `StringColumn`'s `contains` operator.
`Filters::Chips::FullTextStringColumn` is the reusable search-style text base;
until a subject has a database-specific full-text implementation, it uses a
documented cross-database LIKE fallback so development/test SQLite and
production adapters have the same baseline behavior.

Date chips expose `date_precision` metadata. The shared datetime range editor
preserves existing AST value shapes: absolute ranges still use `between:
[from, to]`, relative ranges use `within_last: { n, unit }` and
`more_than_ago: { n, unit }`, and single-sided filters keep their scalar date
or datetime value. The editor adds common presets including today, yesterday,
last 24 hours, last 7 days, last 30 days, this week, and this month; datetime
fields render time-of-day controls, while date-only fields render date inputs.

The spending insights page is a FilterBar-backed surface without SmartFolders.
Its `spending_report` subject (registered by the `spending_insights` plugin) filters `Run` spending by repository, user,
datetime, agent provider, trigger kind, and epic. The page keeps the historical
90-day default by injecting a positive top-level `created_at between ...` chip
when the URL does not provide one; negated or OR date expressions are combined
with that default window instead of being used as the chart bounds.

## View preference persistence

The selected view is persisted per `[subject, smart_folder_id]` pair and restored on next load. Preferences are stored via `User#update_dashboard_folder_preferences!` and resolved by `DashboardPayload#folder_pref_view`. All three view values (`list`, `kanban`, `dependencies`) are valid persisted values.
