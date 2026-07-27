# Agent Insights

Agent insight jobs are infrastructure-flavored analysis runs that inspect a repository's recent workflow history and surface improvement suggestions to the operator. They are read-only: no code changes are committed and no pull request is opened.

## Feature flag

Agent insights are controlled by the `agent_insights` feature flag (default: off). Enable it from the Features page in the admin UI. When the flag is off:

- `agent_insight` jobs cannot be created (validation rejects them with a clear error).
- The `submit_insight` MCP tool is not registered in the sidecar.

## Job kind

`agent_insight` is a separate `Job#kind` alongside `issue`, `cron`, `direct`, and `main_grader`. It shares the same state machine and operator-facing affordances, but is subject to additional constraints:

- `issue_number` must be blank.
- The `agent_insights` feature flag must be enabled at creation time.
- The job auto-closes on both workflow success and failure.

## Workflow chain

```
prepare → agent_insight_run → auto_close
```

**`prepare`** — installs repository dependencies as usual (respects `.syrus.yml` and all standard skip conditions).

**`agent_insight_run`** — agentic step. Invokes the insight prompt against the workspace (read-only). The agent inspects recent Job runs via `read_live_state` and memory tools, then calls `submit_insight` for each finding.

**`auto_close`** — non-agentic step. Closes the anchor Job with reason `agent_insight` so it does not accumulate in the operator dashboard.

## Queue

Insight workflows run on the `default` queue (not `runs`) so they do not consume agent-concurrency budget normally reserved for implementation work. Create insight jobs with `priority: "low"` to avoid starving pollers.

## InsightSuggestion records

Each `submit_insight` call creates one `InsightSuggestion` row:

| Field             | Type    | Description                                                        |
|-------------------|---------|--------------------------------------------------------------------|
| `job`             | FK      | The anchor insight Job.                                           |
| `repository`      | FK      | The analysed repository.                                          |
| `title`           | string  | Concise finding title (≤ 200 chars).                             |
| `category`        | string  | e.g. `repeated_failure`, `inefficiency`, `configuration`, etc.   |
| `severity`        | string  | `low`, `medium`, or `high`.                                       |
| `confidence`      | float   | Agent's confidence (0.0–1.0).                                     |
| `evidence`        | json    | Array of `{job_id, run_id, kind}` objects.                        |
| `suggested_prompt`| text    | Optional prompt for a follow-up Job or ScheduledTask.            |
| `memory_suggestion`| text   | Optional text to store as a memory.                               |
| `state`           | string  | `pending` → `accepted` or `dismissed`.                           |
| `created_job`     | FK      | Populated when the operator promotes the suggestion into a Job.  |

## MCP tools (agent_insight_run role)

The insight agent receives:

- `read_live_state` — inspect the current run/workflow/job/queue state.
- `read_memory`, `search_memories`, `list_memories` — read repository-scoped memories.
- `write_memory` — store durable facts discovered during analysis.
- `submit_insight` — record a finding (only present when `agent_insights` flag is on).

**Scope enforcement:** the `submit_insight` tool validates that `evidence.job_id` values belong to repositories accessible to the running user. Non-admin users cannot reference jobs from repositories they do not own. Admin users may reference any job.
