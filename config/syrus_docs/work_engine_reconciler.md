# Work-Engine Reconciler

`WorkEngine::Reconciler` is the unified work-state consistency classifier and
repair planner. Diagnostic calls are read-only by default: they snapshot evidence
and return structured issue records plus repair plans. The recurring repair path
invokes the same reconciler with repair execution enabled, and it executes only
plans marked `auto_executable`.

Recurring/global reconcile jobs are concurrency-limited by scope. Only one
global reconcile runs at a time, and duplicate global requests are discarded
while one is already pending or executing. Scoped reconciles for a specific Job,
Workflow, or Run use a separate key for that record scope.

## Result shape

`WorkEngine::Reconciler.call(source:, job_id: nil, workflow_id: nil, run_id: nil,
execute_repairs: false)` returns a `WorkEngine::Reconciler::Result` with:

- `source` and `captured_at`
- `snapshot` containing scoped Job, Workflow, Step, Run, SolidQueue,
  SpawnedProcess, worker heartbeat, workspace, main-health, and rate-limit
  evidence
- `issues`, an array of structured issue records
- `repair_plans`, an array of side-effect-free plans
- `repair_executions`, an array of applied/skipped/failed executor results when
  `execute_repairs: true`

Each issue record includes:

- `kind`
- `severity` (`info`, `warning`, `error`, or `critical`)
- `evidence`
- `affected_ids` (`job_ids`, `workflow_ids`, `step_ids`, `run_ids`,
  `solid_queue_job_ids`, `spawned_process_ids`)
- `safe_to_auto_repair`
- `recommended_repair_action`
- `retry_after`
- `check_after`
- `explanation`

Each repair plan includes:

- `issue_kind`
- `action`
- `auto_executable`
- `target_type` and `target_id`
- `affected_ids`
- `execution_steps`, naming the service/model calls a later executor may make
- `preconditions`
- `retry_after`
- `check_after`
- `reason`

Each repair execution includes:

- `action`
- `target_type` and `target_id`
- `status` (`applied`, `skipped`, or `failed`)
- `message`

## Classified issue families

The classifier currently emits these families:

- `queued_run_without_queue_claim`
- `queued_run_solid_queue_failed_execution`
- `queued_run_stale_queue_claim`
- `queued_grader_collect_cached_failure`
- `runs_paused`
- `running_run_without_live_worker_evidence`
- `queued_workflow_without_first_run`
- `running_workflow_without_active_descendants`
- `job_workflow_state_drift`
- `job_without_active_workflow`
- `unambiguous_job_state_drift`
- `completed_main_grader_job`
- `dependency_stack_start_block`
- `stale_dependency_start_block`
- `main_health_start_block`
- `main_branch_broken`
- `resource_congestion`
- `rate_limit`
- `workspace_missing`
- `resumable_agent_session_present`
- `resumable_agent_session_missing`
- `retryable_run_failure`
- `nonretryable_semantic_git_failure`
- `cleanup_blocked_by_active_descendants`
- `workflow_workspace_prune_risk`

`safe_to_auto_repair` only describes whether the repair planner may choose an
automatic action. The classifier and planner are side-effect free; mutations are
centralized in `WorkEngine::RepairExecutor`.

## Repair planning policy

`WorkEngine::RepairPlanner` maps each issue to the narrowest safe action using
the issue evidence, `Step::Kind` repair semantics, workflow trigger kind,
`RunFailureClassifier` output, retry budgets, workspace/session availability,
and external health.

Planner examples:

- A queued Run with no SolidQueue claim returns `reenqueue_run` for the same
  Run.
- A queued Run whose SolidQueue execution failed also returns `reenqueue_run`;
  the persisted Run remains the source of truth.
- A stale queued Run with an existing queue claim returns
  `diagnose_queue_starvation`; it does not duplicate work.
- A queued Run is never planned for `reenqueue_run` while its Workflow has a
  pending (unperformed, unskipped) `AutoRetryAttempt` — that attempt already
  owns recovery for the Workflow, so racing it with a second repair path is
  what turns a single grader failure into a run storm.
- A queued `grader_collect` Run that already lost a queue claim (dead resume
  queue or a failed SolidQueue execution — not the "never had a claim" case)
  returns `operator_review_cached_grader_failure` instead of `reenqueue_run`
  when `GraderConclusionCache` already has a failed aggregate conclusion for
  the Workflow's current head SHA and grader fingerprint: the outcome is
  already known, so re-enqueueing would just replay it. A Run that never had
  a queue claim at all still gets one legitimate `reenqueue_run`, since it
  has to execute once to progress the retry-until loop deterministically.
- Paused Run queues return `wait_for_queue_resume`, preserving the operator's
  pause instead of creating duplicate queue pressure.
- A running Workflow whose previous Step succeeded but whose queued successor
  has no Run returns `resume_queued_step`; the executor calls
  `StepDispatcher.resume_deferred_phase`, so manual pause, provider availability,
  and phase-admission gates are rechecked before the missing Run is created.
- A stale running Run first plans to mark the Run as `worker_died`, then
  prefers `ResumeWorkflowEnqueuer` when an agent session exists, otherwise
  `RetryFailedStepEnqueuer` when the workflow workspace exists, otherwise a
  fresh retry workflow only when the usual workflow retry gate is safe. The
  normal stale-heartbeat deadline remains `Run::STALE_HEARTBEAT_THRESHOLD`
  for ambiguous cases with active worker evidence.
- A detached running Run can become repairable sooner: if the Run is older than
  the normal orphan grace, has no active SolidQueue RunJob (or only a
  `ProcessPrunedError` failed execution), has no live `SpawnedProcess`, and has
  not heartbeated for `DETACHED_WORKER_EVIDENCE_GRACE`, the same worker-died
  repair planner is allowed without waiting for the 30-minute stale-heartbeat
  backstop. Before that grace elapses, the issue remains wait-only and reports
  `check_after` as `last_heartbeat_at + DETACHED_WORKER_EVIDENCE_GRACE`.
- Global rate-limit issues return wait-only `schedule_retry_after_rate_limit`
  plans with `retry_after` from the provider circuit or GitHub reset
  time/backoff. Concrete failed Runs classified as `rate_limited` or
  `provider_usage_limit` return automatic `schedule_retry_after_rate_limit`
  plans that create a delayed `AutoRetryAttempt`. Provider usage limits prefer
  Codex structured usage reset windows, then provider reset text parsed from
  the failure time, then the conservative provider-circuit backoff. When the
  delayed `AutoRetryJob` fires, it re-checks provider availability and
  reschedules the same attempt if the circuit still reports a future
  `retry_after`; it does not consume the attempt as skipped.
- Deterministic idempotent step failures, as declared by `Step::Kind`, may plan
  an in-place failed-step retry when the workspace and retry budget allow it.
- Git publication, landing, and semantic failures return operator-review plans
  unless an existing safe rebuild path is declared, such as merge-train rebuild.
- Main-health, dependency, stack, and capacity blocks return waiting plans, not
  failed retries. If a queued Workflow still has
  `stack_dependencies_not_ready` persisted but the current dependency resolver
  returns no unsatisfied dependencies, the reconciler emits
  `stale_dependency_start_block` with an automatic
  `clear_stale_start_block_and_start_workflow` repair.
- Terminal Workflows with active descendants return operator-review cleanup
  plans, because cleanup must not race still-active Step or Run rows.

## Stuck visibility and explanations

Admin stuck surfaces are reconciler-backed. The dedicated stuck list, token
admin stuck API, `admin_stuck_jobs`, and `explain_stuck_job` all expose the
same issue kinds, evidence, repair plans, and derived attention state. The
admin overview is intentionally read-only against the latest cached stuck
snapshot refreshed by the global reconciler or by opening the dedicated stuck
list; it must not run a global reconciliation inline because that path can be
too expensive for the dashboard and Supervisor `admin_overview` tool.

The React admin overview and dedicated stuck list paginate visible stuck items
in 50-item pages. The `/api/v1/app/admin/stuck` and `/api/v1/admin/stuck`
payloads accept `page` and return live `pagination` metadata with the total
count; the overview embeds the first page from the cached snapshot plus
`stuck_pagination` so the health tile can show the last known total without
rendering every row or blocking on reconciliation.

The admin Reconciler Activity page (`/admin/reconciler_activity`) is the
operator activity log for what the reconciler did and why. Read-only inspections
used by admin stuck surfaces do not create activity rows. Repairing reconciler
runs record `run_started`, detailed issue/plan/execution rows for applied or
failed repair executions, and a `run_finished` or `run_failed` summary. Skipped
executions are aggregated in the summary counts instead of expanded every
minute, so recurring passes do not flood the log with unchanged
operator-review/waiting items. The app API endpoint is
`/api/v1/app/admin/reconciler_activity`; the token admin API endpoint is
`/api/v1/admin/reconciler_activity`. Both are paginated newest-first and accept
`event_type`, `job_id`, `workflow_id`, and `run_id` filters.
`WorkEngineReconcilerActivityPruneJob` keeps the activity table bounded to the
last 7 days.

- `auto_repairable` when the plan is safe for automatic execution
- `waiting` when the plan is blocked by queue capacity, dependency or stack
  readiness, main-branch health, provider rate limits, or queue-claim
  diagnosis
- `operator_action_required` for semantic failures, unsafe state drift, missing
  workspaces, and other non-idempotent cases
- `repaired` when a repair execution result reports an applied action

The stuck copy distinguishes stale queue claims, queue starvation/capacity
pressure, dependency blocks, unsuccessful closed dependencies, main-health
blocks, retryable failed steps, and semantic/operator-needed failures from the
reconciler issue and repair-plan pair.

## Repair execution

`WorkEngine::ReconcileJob` calls the reconciler with `execute_repairs: true`.
The executor:

- skips every plan that is not marked `auto_executable`
- re-checks local preconditions immediately before mutating
- appends system `JobLog` audit entries before and after each action when a Run
  is available
- records direct state transitions with `StateTransition.with_source("reconciler")`
- schedules retry, resume, failed-step, and workflow recovery through
  `AutoRetryAttempt` and `AutoRetryJob` instead of bypassing the retry ledger

Current automatic repairs include re-enqueueing queued Runs with no queue claim,
starting queued Workflows whose first Step has no Run when readiness gates pass,
resuming queued successor Steps that missed the post-success handoff,
clearing stale dependency start blocks whose dependency resolution is now
satisfied,
marking dead running Runs as `worker_died` and scheduling the planned retry path,
retrying or resuming safe failed Runs, finishing running Workflows whose
descendants are terminal, closing completed main-grader Jobs, and applying
unambiguous Job state drift transitions through the legacy state plan.
