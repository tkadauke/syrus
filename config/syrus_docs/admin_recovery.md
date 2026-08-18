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
parent and effective base, and landing queue and merge-train blockers, including
cached PR check and mergeability state.

The tool returns both machine-readable fields and a concise `human_summary`.
Its `recommended_action.action` is one of the operator-facing repair choices
such as `confirm_rebase`, `close_successfully_no_changes`, `retry_job`, `wait`,
`inspect_logs`, or `manual_intervention`. The tool never mutates Job, Workflow,
Run, PR, dependency, or queue state; actions that would mutate state still
require the separate pending-confirmation tools.

## Restart Web / Worker

The operator console's Maintenance section and `POST /api/v1/admin/restart`
(bearer-token API) / `POST /api/v1/app/admin/restart` (session-authenticated,
used by the React admin UI) restart web and/or worker processes without any
environment-specific code — no `kubectl`, no Kubernetes API access, no RBAC.

The mechanism is a shared cache "poison pill": `Admin::RestartService` writes
a UTC timestamp to `Rails.cache` under `syrus:restart_web` and/or
`syrus:restart_worker` (component `all` writes both). Every web and worker
process runs a `RestartWatcher` background thread (started by
`config/initializers/restart_watcher.rb`, gated the same way as
`InstanceVersionSupervisor` — only when `SyrusVersion.server_process?`, so it
never runs in the console, test suite, or asset compilation) that polls its
own role-scoped key every 10 seconds. When it finds a timestamp newer than
its own start time, it logs, sleeps a random 0-20s jitter (staggers
multi-pod/container restarts so the platform can replace one instance before
the next goes down), then sends itself `SIGTERM`. The platform's existing
restart policy brings the process back — Kubernetes' pod restart policy,
Docker Compose's `restart: unless-stopped` (already set on `web` and `worker`
in `docker-compose.yml`), or foreman in local dev.

Because each process compares the poison-pill timestamp against its own boot
time, a freshly restarted process ignores the old timestamp instead of
restarting in a loop. The cache entry expires after 5 minutes.

Restarting `worker` or `all` is refused with `409` (`initiated: false`,
`active_runs: N`) when Runs are in `queued`/`running` state, unless the
request passes `force: true`. Restarting `web` alone never checks active Runs.
Every restart request — successful or refused-then-forced — is recorded via
`AdminAction.log!` (`action: "restart"`) with `component`, `source`
(`"api"` or `"app"`), `force`, and the active-run count observed at request
time, visible in the console's Recent Admin Actions table.

## Stale Run Reap

The admin-only stale-run reap action defers to the unified work-engine
reconciler, which handles stale Runs, orphaned queued Runs, queued Workflows
with no first Run, terminal orphan Workflows, and missed worker-death
auto-retries.

The reconciler also cancels queued automatic retry Workflows when the failed
source Workflow has already been superseded by a newer successful Workflow. In
that case cancellation takes precedence over re-enqueueing any stale queued Run
inside the retry Workflow, so old auto-retry debris does not re-open completed
work.
