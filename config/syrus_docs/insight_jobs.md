# Agent Insight Jobs

## Overview

Agent insight jobs (`kind: "agent_insight"`) are analysis runs that inspect a repository's recent workflow history and surface improvement suggestions as `InsightSuggestion` records. They are designed for periodic health checks — an agent reviews recent jobs, identifies patterns (repeated failures, inefficiencies, gaps in agent memory, recurring tasks that could be automated), and records structured suggestions for the operator to review, accept, or dismiss.

Insight jobs are read-only: they never commit to the repository, never open a pull request, and auto-close once the analysis completes (success or failure).

## Enabling Agent Insights

The feature is gated by the `agent_insights` feature flag (Labs category, default off). Enable it from the Features admin page:

```
Admin → Features → Agent Insights → Enable
```

Or via Rails console:

```ruby
Feature.find_by!(slug: "agent_insights").update!(enabled: true)
```

Once enabled, the following become active:
- "Run insight analysis" button on repository pages
- `/repositories/:id/insights` — per-repository suggestions list
- `/admin/insights` — cross-repository admin view
- `POST /api/v1/app/repositories/:id/run_insight_analysis` API endpoint
- `GET /api/v1/app/repositories/:id/insight_suggestions` API endpoint
- `PATCH /api/v1/app/insight_suggestions/:id` API endpoint
- `GET /api/v1/app/admin/insights` API endpoint (admin only)
- `POST /api/v1/app/admin/insights/:id/promote_memory` API endpoint (admin only)
- The `submit_insight` MCP tool is available to agents running in insight workflows
- The `list_insights` and `read_insight` MCP tools are available to regular chat agents through the deferred chat sidecar
- The `read_run_worker_health` MCP tool is available so insight agents can use
  retained worker host pressure and grader command-span pressure as evidence
  for Run, Step, and phase-level patterns

All endpoints and routes return 404 when the feature flag is off.

## Triggering an Insight Run

**Via the UI:** Navigate to a repository page → click "Run insight analysis". The button is hidden when the feature is off. If an insight job is already running for that repository, clicking the button shows the active job instead of creating a duplicate.

**Via the API:**

```
POST /api/v1/app/repositories/:id/run_insight_analysis
```

Returns the standard repository detail payload with a notice that the job was started (or that one is already running).

## What the Agent Analyzes

The agent receives a read-only view of the repository's workspace and recent job history (last 14 days, up to 50 `issue`-kind jobs). It uses the `submit_insight` MCP tool to record findings — one call per distinct pattern. It can also call `read_run_worker_health(run_id:)` to inspect retained CPU, memory, disk, CPU pressure, and IO pressure samples for a specific Run window, including whether the Run's history was clipped by the worker-health retention window. Grader and preflight grader Runs may include `command_spans`, which let the agent attribute pressure or latency to phases like dependency checks, installs, database preparation, backend tests, or frontend builds instead of only the full Run window. Durable `run_resource_summaries` retain this Run-level view for 30 days and keep host-correlated pressure fields separate from process-attributed command metrics, with explicit low-confidence fallback markers when command attribution is unavailable.

Each `InsightSuggestion` captures:
- **title** — concise description of the finding (≤ 200 chars)
- **category** — e.g., `repeated_failure`, `inefficiency`, `configuration`, `memory_gap`, `recurring_task`
- **severity** — `low`, `medium`, or `high`
- **confidence** — 0.0–1.0 score
- **evidence** — array of `{job_id, run_id, kind}` supporting evidence
- **proposal_type** — explicit action: `create_job`, `save_memory`, `remove_memory`, `revise_existing_insight`, or `informational`; existing rows that only have prompt/memory fields infer their legacy type
- **suggested_prompt** — optional prompt text for a Job or ScheduledTask that would address the finding
- **memory_suggestion** — optional text to store as an agent memory for future runs
- **target_memory_id**, **stale_memory_text**, **stale_memory_evidence** — structured stale-memory removal proposal fields
- **target_insight_id** — existing insight referenced by a revision/retirement proposal

## Reviewing Suggestions

Navigate to `/repositories/:id/insights` to see suggestions for a repository, ordered by severity (high → low) then confidence (high → low). Filter by state: Pending, Accepted, Dismissed, or All. Lists are paginated, and the state counts reflect all matching suggestions, not only the current page.

Regular chat agents can inspect the same suggestions with `list_insights` and
`read_insight`. Non-admin chat agents can only list/read suggestions for the
chat's attached repositories; inaccessible insight ids return a generic
not-found/not-accessible error. Admin chat agents can inspect all suggestions and
can narrow broad reads with `repository_id`, `state`, `limit`, and `page`.
Chat agents do not receive `submit_insight`; suggestion creation remains tied to
agent insight workflows because that tool records against the anchor insight Job
and its workflow artifacts.

Each suggestion shows:
- Title, category tag, severity pill, confidence percentage, and age
- Clickable evidence links to jobs and run transcripts
- Expandable detail showing the suggested prompt and memory suggestion text
- Remove-memory proposals render as destructive stale-memory cards with the target memory id, stale text, and evidence

### Accept

Click **Accept** to open a confirmation form. The form pre-fills with the suggested prompt (if any). You can:
- Edit the prompt text
- Confirm to mark the suggestion accepted and create a direct Job from the prompt

The `accepted_at` timestamp is recorded, and `created_job_id` links back to the created Job.

For `remove_memory` suggestions, **Remove memory** accepts the suggestion and
soft-deletes the target `ChatMemory` through `ChatMemory#soft_delete_by!`.
Non-admin operators can only remove memories they are allowed to delete; admins
can accept stale-memory removals from the admin insight view. The insight agent
never deletes memories directly.

### Dismiss

Click **Dismiss** to confirm and mark the suggestion dismissed. The `dismissed_at` timestamp is recorded. Dismissed suggestions can be restored from the Dismissed tab with **Undismiss**, which returns them to Pending; accepted suggestions cannot be reopened.

### Save as Memory

When `memory_suggestion` is present, a **Save as memory** button appears on pending and accepted suggestions. Clicking it creates a `ChatMemory` record with:
- `kind: "project_fact"`
- `scope: "repository"` (scoped to this repository)
- `source_type: "insight"`, `source_id: <suggestion_id>`
- `author: "agent"`
- `confidence: <suggestion.confidence>`

The memory becomes available to future agents working on the same repository.

## Admin View

`/admin/insights` shows a paginated, state-filterable cross-repository table of all suggestions (requires admin role + feature flag on). Each row includes the repository slug, the user who owns the source job, severity, confidence, and state.

Admins can expand rows to see the full suggested prompt, memory suggestion, and
stale-memory removal evidence. They can **Promote to instance memory** for
memory suggestions — this creates a `ChatMemory` with `scope: "instance"` rather
than `scope: "repository"`, making it visible to all agents across all
repositories. For `remove_memory` suggestions, admins can accept the removal
from the table.

## Concurrent Insight Jobs

Syrus enforces at-most-one active insight job per repository. If an insight job is already running when "Run insight analysis" is clicked, a notice is shown and no new job is created. Once the active job closes (success or failure), a new run can be triggered.

## Adaptive Scheduling

In addition to on-demand runs, Syrus can automatically schedule insight jobs based on coding job activity. This eliminates the need for fixed time intervals: insight jobs fire when there is genuinely new work to analyze, not on a calendar.

### Settings UI

When the `agent_insights` feature flag is on, an **Insight Scheduling** section appears at the bottom of each repository's edit page (`/repositories/:id/edit`). It has its own Save and Discard buttons separate from the main repository form:

- **Enable automatic insights** — toggle to enable or disable adaptive scheduling for this repository.
- **Minimum jobs** — integer ≥ 1 (default 5). The periodic sweep threshold: `InsightSweepJob` runs every 6 hours and fires an insight job if the count of closed coding jobs since the last insight run is ≥ this value.
- **Maximum jobs** — integer ≥ 2, must be greater than Minimum (default 10). The immediate trigger threshold: fires an insight job right away when a coding job closes and the count reaches this value.

Validation requires `min < max`; the form enforces this client-side before submitting and the server validates it as well.

### API

- `GET /api/v1/app/repositories/:id/insight_schedule_config` — returns the current config (`enabled`, `min_jobs_since_last_run`, `max_jobs_since_last_run`). Returns defaults if no record exists yet.
- `PATCH /api/v1/app/repositories/:id/insight_schedule_config` — updates `enabled`, `min_jobs_since_last_run`, and/or `max_jobs_since_last_run`. Returns 422 on validation failure.

Both endpoints return 403 if the `agent_insights` feature flag is off.

### Status badge

On the repository overview page, a small status badge appears next to the "Run insight analysis" button:

- **Auto: off** — automatic scheduling is disabled.
- **Auto: on (min 5 / max 10)** — automatic scheduling is enabled, showing the configured thresholds.

### Console / Rails

Adaptive scheduling is also configurable via Rails:

```ruby
repo = Repository.find_by!(owner: "acme", name: "widgets")
config = repo.insight_schedule_config || repo.build_insight_schedule_config
config.update!(
  enabled: true,
  min_jobs_since_last_run: 5,   # sweep threshold
  max_jobs_since_last_run: 10   # immediate trigger threshold
)
```

### Thresholds

Two thresholds control when insight jobs fire automatically:

- **`min_jobs_since_last_run`** (default: 5) — the periodic sweep threshold. `InsightSweepJob` runs every 6 hours and fires an insight job for any enabled repository whose count of closed coding jobs since the last insight run is ≥ `min`.
- **`max_jobs_since_last_run`** (default: 10) — the immediate trigger threshold. Whenever any coding job closes, if the count of closed coding jobs since the last insight run reaches ≥ `max`, an insight job is enqueued immediately without waiting for the next sweep.

Both thresholds count closed jobs of any kind except `agent_insight`, measured from the `finished_at` of the most recently created `agent_insight` job (or from the beginning of time if none exists). Weekends and idle periods are skipped naturally: the count only crosses `min` if real work has occurred.

### Deduplication

Both the sweep and the immediate trigger call `InsightScheduler.enqueue_if_idle!`, which first checks whether a non-closed `agent_insight` job already exists for the repository. If one is queued or running, no new job is created.

### Validation

- Both `min_jobs_since_last_run` and `max_jobs_since_last_run` must be ≥ 1.
- `min_jobs_since_last_run` must be strictly less than `max_jobs_since_last_run`.

## Job Lifecycle

- **Branch:** Insight jobs do not create a branch — they operate on a shallow clone of the default branch read-only.
- **Auto-close:** The anchor Job is automatically closed once the insight workflow finishes (success or failure), so insight jobs do not accumulate in the dashboard.
- **Retries:** Insight jobs do not retry automatically. Trigger a new run manually if needed.
- **Queue:** Insight workflows use the `:runs` queue with low Job priority.
