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
| `state`           | string  | `pending` → `accepted` or `dismissed`; dismissed suggestions can return to `pending`. Any of `pending`/`dismissed` (and, with an explicit override, `accepted`) can transition to `retired`, a terminal audited state. |
| `retired_at`      | datetime| Set when the insight is retired.                                  |
| `retired_reason`  | text    | Required explanation recorded on retirement.                      |
| `superseded_by_insight` | FK | Optional insight that supersedes this retired one.            |
| `superseded_by_job` | FK   | Optional Job that resolved or replaced this retired finding.      |
| `created_job`     | FK      | Populated when the operator promotes the suggestion into a Job.  |

### Retirement

`retire_insight` is an audited state transition, not a physical delete: retired
rows keep their full history and stay inspectable via `list_insights(state:
"retired")`/`state: "all"` and `read_insight`. Pending and dismissed insights
retire directly. Accepted insights are refused by default — accepted insights
are operator history, so the normal path is filing a new standalone insight
that supersedes the accepted one — unless the caller explicitly passes
`retire_accepted: true`, a distinct override reserved for accepted insights
that are themselves confirmed obsolete. Every retirement records a
`retired` `InsightSuggestionAuditEvent` with the previous/new state and
retirement fields, the actor (run/user/system), and the reason.

Repository and admin insight list views default to the `pending` tab, so
retired insights are excluded from the default active-review surface without
any extra filtering. Both views accept an explicit `state=retired` (or
`state=all`, which includes retired rows) to inspect retired insights.

A one-off cleanup path retires the pre-existing stale backlog — pending or
dismissed legacy `revise_existing_insight` rows and pending or dismissed
`informational` rows titled `Superseded by #...` — without manual DB work:

```
bin/rails syrus:retire_stale_insight_backlog        # retire
DRY_RUN=true bin/rails syrus:retire_stale_insight_backlog  # preview only
```

This runs `InsightSuggestions::StaleBacklogRetirement`, which retires each
matching row through the normal `InsightSuggestion#retire!` audit path with a
`system` actor.

## MCP tools

### Agent insight runs

The insight agent receives:

- `read_live_state` — inspect the current run/workflow/job/queue state.
- `list_recent_workflows` — list completed Workflows for the current repository after the previous insight cutoff (or an explicit ISO8601 `since`).
- `read_run_transcript` — read paginated JobLog transcript chunks plus agent summary/diff for a Run in the current repository, with secret-shaped values redacted.
- `read_run_worker_health` — inspect worker host health correlated with a Run in the current repository.
- `read_syrus_logs` — search recent indexed Rails application logs for repeated exceptions, recurring warnings, slow behavior, retry storms, queue/worker anomalies, failed background jobs, and noisy code paths. This tool is provided by the `syrus_dev` plugin and returns data only when `operational_log_indexing` is enabled and the current repository is `tkadauke/syrus` or a registered fork/upstream. Operational log ingestion uses the shared observability sink: request/job hot paths append to per-process memory plus a local JSONL spool, and each process has a lazy background flusher that persists rows to `operational_log_events` and the FTS index in batches. The searchable retention window is 6 hours.
- `read_memory`, `search_memories`, `list_memories` — read repository-scoped memories.
- `write_memory` — store durable facts discovered during analysis.
- `submit_insight` — record a new finding (only present when `agent_insights` flag is on), including structured memory-removal proposals.
- `update_insight` — revise a pending or dismissed existing insight in place with an audit event. Accepted insights are rejected and should be handled by filing a new standalone insight that cites the accepted prior insight as context.
- `retire_insight` — retire a pending or dismissed insight that is stale, duplicated, or superseded, with a required `reason` and optional `superseded_by_insight_id`/`superseded_by_job_id`. Accepted insights are rejected unless `retire_accepted: true` is passed explicitly. Records a `retired` audit event; the row stays inspectable, never deleted.

**Scope enforcement:** workflow evidence tools are constrained to the current insight run's repository. `submit_insight` also validates that `evidence.job_id` values belong to repositories accessible to the running user. Non-admin users cannot reference jobs from repositories they do not own. Admin users may reference any job.

Operational log matches should be treated as investigative evidence, not as
standalone proof. Insight findings should include log evidence plus workflow or
run context when possible: affected Job/Run ids, transcript excerpts, correlated
worker health, code paths, or repeated occurrences across the log window. Avoid
filing insights from one-off benign log lines or isolated noise.

Insight runs must review pending, accepted, and dismissed insights for freshness
before filing new ones. When an unaccepted insight's details need correcting but
the finding is still active, call `update_insight` to revise it in place. When
an unaccepted insight is stale, duplicated, folded into another insight, or no
longer worth any operator review, call `retire_insight` instead of filing a new
informational "Superseded by #N" card. When an accepted insight is changed by a
novel realization, create a new insight rather than updating or retiring the
accepted row (unless the accepted insight itself is confirmed obsolete, in which
case `retire_insight(..., retire_accepted: true)` applies). They
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
