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

All endpoints and routes return 404 when the feature flag is off.

## Triggering an Insight Run

**Via the UI:** Navigate to a repository page → click "Run insight analysis". The button is hidden when the feature is off. If an insight job is already running for that repository, clicking the button shows the active job instead of creating a duplicate.

**Via the API:**

```
POST /api/v1/app/repositories/:id/run_insight_analysis
```

Returns the standard repository detail payload with a notice that the job was started (or that one is already running).

## What the Agent Analyzes

The agent receives a read-only view of the repository's workspace and recent job history (last 14 days, up to 50 `issue`-kind jobs). It uses the `submit_insight` MCP tool to record findings — one call per distinct pattern.

Each `InsightSuggestion` captures:
- **title** — concise description of the finding (≤ 200 chars)
- **category** — e.g., `repeated_failure`, `inefficiency`, `configuration`, `memory_gap`, `recurring_task`
- **severity** — `low`, `medium`, or `high`
- **confidence** — 0.0–1.0 score
- **evidence** — array of `{job_id, run_id, kind}` supporting evidence
- **suggested_prompt** — optional prompt text for a Job or ScheduledTask that would address the finding
- **memory_suggestion** — optional text to store as an agent memory for future runs

## Reviewing Suggestions

Navigate to `/repositories/:id/insights` to see all suggestions for a repository, ordered by severity (high → low) then confidence (high → low). Filter by state: Pending, Accepted, Dismissed, or All.

Each suggestion shows:
- Title, category tag, severity pill, confidence percentage
- Clickable evidence links to jobs and run transcripts
- Expandable detail showing the suggested prompt and memory suggestion text

### Accept

Click **Accept** to open a confirmation form. The form pre-fills with the suggested prompt (if any). You can:
- Edit the prompt text
- Toggle whether to create a direct Job from the prompt
- Confirm to mark the suggestion accepted (and optionally create the job)

The `accepted_at` timestamp is recorded, and if a job was created, `created_job_id` links back to it.

### Dismiss

Click **Dismiss** to mark the suggestion dismissed. The `dismissed_at` timestamp is recorded. Accepted and dismissed suggestions cannot be re-opened; create a new direct job manually if needed.

### Save as Memory

When `memory_suggestion` is present, a **Save as memory** button appears. Clicking it creates a `ChatMemory` record with:
- `kind: "project_fact"`
- `scope: "repository"` (scoped to this repository)
- `source_type: "insight"`, `source_id: <suggestion_id>`
- `author: "agent"`
- `confidence: <suggestion.confidence>`

The memory becomes available to future agents working on the same repository.

## Admin View

`/admin/insights` shows a cross-repository table of all suggestions (requires admin role + feature flag on). Each row includes the repository slug, the user who owns the source job, severity, confidence, and state.

Admins can expand rows to see the full suggested prompt and memory suggestion, and can **Promote to instance memory** — this creates a `ChatMemory` with `scope: "instance"` rather than `scope: "repository"`, making it visible to all agents across all repositories.

## Concurrent Insight Jobs

Syrus enforces at-most-one active insight job per repository. If an insight job is already running when "Run insight analysis" is clicked, a notice is shown and no new job is created. Once the active job closes (success or failure), a new run can be triggered.

## Job Lifecycle

- **Branch:** Insight jobs do not create a branch — they operate on a shallow clone of the default branch read-only.
- **Auto-close:** The anchor Job is automatically closed once the insight workflow finishes (success or failure), so insight jobs do not accumulate in the dashboard.
- **Retries:** Insight jobs do not retry automatically. Trigger a new run manually if needed.
- **Queue:** Insight workflows use the `:default` queue.
