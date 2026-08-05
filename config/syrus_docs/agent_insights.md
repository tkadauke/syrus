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

**`agent_insight_run`** — agentic step. Invokes the insight prompt against the workspace (read-only). The agent discovers recent completed Workflows with `list_recent_workflows`, reads paginated Run JobLog transcripts with `read_run_transcript`, inspects host pressure with `read_run_worker_health` when relevant, searches operational logs with `read_syrus_logs` when that tool is available, checks memory/insight context, then calls `submit_insight` for each finding.

**`auto_close`** — non-agentic step. Closes the anchor Job with reason `agent_insight` so it does not accumulate in the operator dashboard.

## Queue

Insight workflows run on the `runs` queue because their agentic steps are still `RunJob` executions. Create insight jobs with `priority: "low"` so implementation work stays ahead of periodic analysis.

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
| `proposal_type`   | string  | `create_job`, `save_memory`, `remove_memory`, or `informational`. Legacy `revise_existing_insight` rows may still exist but new insight runs should not create them. |
| `suggested_prompt`| text    | Optional prompt for a follow-up Job or ScheduledTask.            |
| `memory_suggestion`| text   | Optional text to store as a memory.                               |
| `target_memory`   | FK      | Memory proposed for audited removal on `remove_memory` suggestions. |
| `stale_memory_text` | text  | Snapshot of stale/wrong memory text.                              |
| `stale_memory_evidence` | text | Explanation of why the memory no longer matches current reality. |
| `target_insight`  | FK      | Legacy revision reference retained for old rows.                 |
| `state`           | string  | `pending` → `accepted` or `dismissed`; dismissed suggestions can return to `pending`. |
| `created_job`     | FK      | Populated when the operator promotes the suggestion into a Job.  |

## MCP tools

### Agent insight runs

The insight agent receives:

- `read_live_state` — inspect the current run/workflow/job/queue state.
- `list_recent_workflows` — list completed Workflows for the current repository after the previous insight cutoff (or an explicit ISO8601 `since`).
- `read_run_transcript` — read paginated JobLog transcript chunks plus agent summary/diff for a Run in the current repository, with secret-shaped values redacted.
- `read_run_worker_health` — inspect worker host health correlated with a Run in the current repository.
- `read_syrus_logs` — search recent indexed Rails application logs for repeated exceptions, recurring warnings, slow behavior, retry storms, queue/worker anomalies, failed background jobs, and noisy code paths. This tool is present only when `operational_log_indexing` is enabled and the current repository is `tkadauke/syrus` or a registered fork/upstream.
- `read_memory`, `search_memories`, `list_memories` — read repository-scoped memories.
- `write_memory` — store durable facts discovered during analysis.
- `submit_insight` — record a new finding (only present when `agent_insights` flag is on), including structured memory-removal proposals.
- `update_insight` — revise a pending or dismissed existing insight in place with an audit event. Accepted insights are rejected and should be handled by filing a new standalone insight that cites the accepted prior insight as context.

**Scope enforcement:** workflow evidence tools are constrained to the current insight run's repository. `submit_insight` also validates that `evidence.job_id` values belong to repositories accessible to the running user. Non-admin users cannot reference jobs from repositories they do not own. Admin users may reference any job.

Operational log matches should be treated as investigative evidence, not as
standalone proof. Insight findings should include log evidence plus workflow or
run context when possible: affected Job/Run ids, transcript excerpts, correlated
worker health, code paths, or repeated occurrences across the log window. Avoid
filing insights from one-off benign log lines or isolated noise.

Insight runs must review pending, accepted, and dismissed insights for freshness
before filing new ones. When an unaccepted insight is stale, duplicated, or
incomplete, call `update_insight` instead of filing a new revision card. When an
accepted insight is changed by a novel realization, create a new insight. They
should call `list_memories` / `read_memory` for
repository-relevant memories and compare them with current code, docs, recent
jobs, and accepted implementation state. If a memory is stale or wrong, the
agent files a `remove_memory` insight with `target_memory_id`,
`stale_memory_text`, and `stale_memory_evidence`; it must not call
`delete_memory` directly during analysis. Operators accept removal proposals
through the application, which soft-deletes the memory via
`ChatMemory#soft_delete_by!` and records the normal audit event.

### Regular chat agents

When `agent_insights` is enabled, regular chat agents can discover and call
`list_insights` and `read_insight` from the deferred chat sidecar. Non-admin
chat agents are limited to the current chat's attached repositories. Admin chat
agents can list/read suggestions across repositories, and should use the
`repository_id`, `state`, `limit`, and `page` filters to keep broad reads
deliberate.

`submit_insight` stays limited to `agent_insight_run` workflows. It creates
suggestions on the current anchor insight Job and updates workflow artifacts, so
chat-originated insight creation is not a supported product behavior.
