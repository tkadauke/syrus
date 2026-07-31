# Work-Engine Reconciler

`WorkEngine::Reconciler` is the unified work-state consistency classifier and
repair planner used by the `unified_work_engine_reconciler` operations feature
flag. The current foundation is read-only: it snapshots evidence and returns
structured issue records plus repair plans. It does not mutate Jobs,
Workflows, Steps, Runs, queue rows, process rows, workspaces, or retry state.

## Result shape

`WorkEngine::Reconciler.call(source:, job_id: nil, workflow_id: nil, run_id: nil)`
returns a `WorkEngine::Reconciler::Result` with:

- `source` and `captured_at`
- `snapshot` containing scoped Job, Workflow, Step, Run, SolidQueue,
  SpawnedProcess, worker heartbeat, workspace, main-health, and rate-limit
  evidence
- `issues`, an array of structured issue records
- `repair_plans`, an array of side-effect-free plans for a later executor

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

## Classified issue families

The read-only classifier currently emits these families:

- `queued_run_without_queue_claim`
- `queued_run_stale_queue_claim`
- `running_run_without_live_worker_evidence`
- `queued_workflow_without_first_run`
- `running_workflow_without_active_descendants`
- `job_workflow_state_drift`
- `dependency_stack_start_block`
- `main_health_start_block`
- `resource_congestion`
- `rate_limit`
- `workspace_missing`
- `resumable_agent_session_present`
- `resumable_agent_session_missing`
- `retryable_run_failure`
- `nonretryable_semantic_git_failure`

`safe_to_auto_repair` only describes whether the repair planner may choose an
automatic action. The classifier and planner are intentionally side-effect free.

## Repair planning policy

`WorkEngine::RepairPlanner` maps each issue to the narrowest safe action using
the issue evidence, `Step::Kind` repair semantics, workflow trigger kind,
`RunFailureClassifier` output, retry budgets, workspace/session availability,
and external health.

Planner examples:

- A queued Run with no SolidQueue claim returns `reenqueue_run` for the same
  Run.
- A stale queued Run with an existing queue claim returns
  `diagnose_queue_starvation`; it does not duplicate work.
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
