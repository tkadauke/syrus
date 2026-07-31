# Admin Recovery

Syrus exposes narrow admin-only recovery actions for Jobs that are open but
stuck outside the normal workflow state propagation path.

## Force Fail Job

`POST /api/v1/admin/jobs/:id/force_fail` moves a non-closed, non-failed Job to
`failed` and returns the updated admin Job JSON. This is intended for recovery
cases such as a Job left `running` after its Workflow was cancelled or otherwise
stopped without propagating failure back to the Job.

The action is deliberately not a generic force-state endpoint. It only targets
`failed`, which keeps the Job open and lets operators use the normal Retry
workflow afterward. Closed Jobs return `422 validation_failed`.

The React admin stuck page surfaces a `Force fail` button for stuck Jobs in
`running`, `queued`, `implemented`, `approved`, or `landing`. Chat agents can
request the same recovery through the admin-only `force_fail_job` MCP tool; the
tool creates a pending action and does not mutate the Job until the operator
confirms it.

## Close Job Successfully

Chat agents can request `close_job_successfully(job_id, closure_reason:, comment:)`
when an existing Job should be semantically closed as successful rather than
cancelled. The tool creates a pending action and never changes Job or PR state
until the operator confirms it.

`closure_reason` must be one of `Job::SUCCESSFUL_CLOSURE_REASONS`; the common
repair case is `no_changes`, which satisfies Job dependencies and Epic progress.
This is distinct from `cancel_job`, whose `cancelled` closure remains
non-successful.

On confirmation, Syrus cancels active execution records for the Job only to make
the close coherent, preserves the historical Workflow/Run rows, and calls
`Job#close_with_reason!`. If the Job tracks a PR and GitHub credentials are
available, Syrus posts the optional explanatory comment and closes the PR. If
GitHub comment or PR close fails, the Job still records the successful closure
and the chat outcome message reports the partial PR cleanup result.

## Explain Stuck Job

Chat agents can call `explain_stuck_job(job_id)` to get a read-only structured
diagnosis for one Job, whether or not the Job currently appears in the global
admin stuck list. The payload includes the Job state, latest and active
Workflow summaries, Run heartbeat evidence, dependency blockers, selected stack
parent and effective base, landing queue and merge-train blockers, cached PR
check and mergeability state, and best-effort PR base / empty-reconciliation
evidence from GitHub.

The tool returns both machine-readable fields and a concise `human_summary`.
Its `recommended_action.action` is one of the operator-facing repair choices
such as `confirm_rebase`, `close_successfully_no_changes`, `retry_job`, `wait`,
`inspect_logs`, or `manual_intervention`. The tool never mutates Job, Workflow,
Run, PR, dependency, or queue state; actions that would mutate state still
require the separate pending-confirmation tools.

## Stale Run Reap

The admin-only stale-run reap action normally enqueues `ReapStaleRunsJob`,
which runs the legacy recovery paths for stale Runs, orphaned queued Runs,
queued Workflows with no first Run, terminal orphan Workflows, and missed
worker-death auto-retries.

When the `unified_work_engine_reconciler` feature flag is enabled, the same
admin action defers to the unified work-engine reconciler instead of enqueueing
the legacy mutation path.
