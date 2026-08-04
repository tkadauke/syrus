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

**`agent_insight_run`** — agentic step. Invokes the insight prompt against the workspace (read-only). The agent discovers recent completed Workflows with `list_recent_workflows`, reads paginated Run JobLog transcripts with `read_run_transcript`, inspects host pressure with `read_run_worker_health` when relevant, checks memory/insight context, then calls `submit_insight` for each finding.

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
| `proposal_type`   | string  | `create_job`, `save_memory`, `remove_memory`, `revise_existing_insight`, or `informational`. Legacy rows infer this from prompt/memory fields. |
| `suggested_prompt`| text    | Optional prompt for a follow-up Job or ScheduledTask.            |
| `memory_suggestion`| text   | Optional text to store as a memory.                               |
| `target_memory`   | FK      | Memory proposed for audited removal on `remove_memory` suggestions. |
| `stale_memory_text` | text  | Snapshot of stale/wrong memory text.                              |
| `stale_memory_evidence` | text | Explanation of why the memory no longer matches current reality. |
| `target_insight`  | FK      | Existing insight referenced by `revise_existing_insight`.        |
| `state`           | string  | `pending` → `accepted` or `dismissed`.                           |
| `created_job`     | FK      | Populated when the operator promotes the suggestion into a Job.  |

## MCP tools

### Agent insight runs

The insight agent receives:

- `read_live_state` — inspect the current run/workflow/job/queue state.
- `list_recent_workflows` — list completed Workflows for the current repository after the previous insight cutoff (or an explicit ISO8601 `since`).
- `read_run_transcript` — read paginated JobLog transcript chunks plus agent summary/diff for a Run in the current repository, with secret-shaped values redacted.
- `read_run_worker_health` — inspect worker host health correlated with a Run in the current repository.
- `read_memory`, `search_memories`, `list_memories` — read repository-scoped memories.
- `write_memory` — store durable facts discovered during analysis.
- `submit_insight` — record a finding (only present when `agent_insights` flag is on), including structured removal/revision proposals.

**Scope enforcement:** workflow evidence tools are constrained to the current insight run's repository. `submit_insight` also validates that `evidence.job_id` values belong to repositories accessible to the running user. Non-admin users cannot reference jobs from repositories they do not own. Admin users may reference any job.

Insight runs must review pending, accepted, and dismissed insights for freshness
before filing new ones. They should call `list_memories` / `read_memory` for
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
