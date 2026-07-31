# Work-Engine Reconciler

`WorkEngine::Reconciler` is the unified work-state consistency classifier and
repair planner used by the `unified_work_engine_reconciler` operations feature
flag. Diagnostic calls are read-only by default: they snapshot evidence and
return structured issue records plus repair plans. The feature-gated recurring
repair path invokes the same reconciler with repair execution enabled, and it
executes only plans marked `auto_executable`.

## Result shape

`WorkEngine::Reconciler.call(source:, job_id: nil, workflow_id: nil, run_id: nil,
execute_repairs: false)` returns a `WorkEngine::Reconciler::Result` with:

- `source` and `captured_at`
- `snapshot` containing scoped Job, Workflow, Step, Run, SolidQueue,
  SpawnedProcess, worker heartbeat, workspace, main-health, and rate-limit
  evidence
- `issues`, an array of structured issue records
- `repair_plans`, an array of plans
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
- `runs_paused`
- `running_run_without_live_worker_evidence`
- `queued_workflow_without_first_run`
- `running_workflow_without_active_descendants`
- `job_workflow_state_drift`
- `job_without_active_workflow`
- `unambiguous_job_state_drift`
- `completed_main_grader_job`
- `dependency_stack_start_block`
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
- Paused Run queues return `wait_for_queue_resume`, preserving the operator's
  pause instead of creating duplicate queue pressure.
- A stale running Run first plans to mark the Run as `worker_died`, then
  prefers `ResumeWorkflowEnqueuer` when an agent session exists, otherwise
  `RetryFailedStepEnqueuer` when the workflow workspace exists, otherwise a
  fresh retry workflow only when the usual workflow retry gate is safe.
- Rate-limit issues and rate-limited Run failures return
  `schedule_retry_after_rate_limit` with `retry_after` from the provider circuit
  or GitHub reset time/backoff. They do not create immediate retry loops.
- Deterministic idempotent step failures, as declared by `Step::Kind`, may plan
  an in-place failed-step retry when the workspace and retry budget allow it.
- Git publication, landing, and semantic failures return operator-review plans
  unless an existing safe rebuild path is declared, such as merge-train rebuild.
- Main-health, dependency, stack, and capacity blocks return waiting plans, not
  failed retries.
- Terminal Workflows with active descendants return operator-review cleanup
  plans, because cleanup must not race still-active Step or Run rows.

## Stuck visibility and explanations

Admin stuck surfaces are reconciler-backed. The admin overview health tile,
dedicated stuck list, token admin stuck API, `admin_stuck_jobs`, and
`explain_stuck_job` all expose the same issue kinds, evidence, repair plans,
and derived attention state:

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

`WorkEngine::ReconcileJob` calls the reconciler with `execute_repairs: true`
when the feature flag is enabled and legacy fixers defer to it. The executor:

- skips every plan that is not marked `auto_executable`
- re-checks local preconditions immediately before mutating
- appends system `JobLog` audit entries before and after each action when a Run
  is available
- records direct state transitions with `StateTransition.with_source("reconciler")`
- schedules retry, resume, failed-step, and workflow recovery through
  `AutoRetryAttempt` and `AutoRetryJob` instead of bypassing the retry ledger

Current automatic repairs include re-enqueueing queued Runs with no queue claim,
starting queued Workflows whose first Step has no Run when readiness gates pass,
marking dead running Runs as `worker_died` and scheduling the planned retry path,
retrying or resuming safe failed Runs, finishing running Workflows whose
descendants are terminal, closing completed main-grader Jobs, and applying
unambiguous Job state drift transitions through the legacy state plan.
