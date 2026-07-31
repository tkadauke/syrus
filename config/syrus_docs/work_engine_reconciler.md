# Work-Engine Reconciler

`WorkEngine::Reconciler` is the unified work-state consistency classifier used
by the `unified_work_engine_reconciler` operations feature flag. The current
foundation is read-only: it snapshots evidence and returns structured issue
records. It does not mutate Jobs, Workflows, Steps, Runs, queue rows, process
rows, workspaces, or retry state.

## Result shape

`WorkEngine::Reconciler.call(source:, job_id: nil, workflow_id: nil, run_id: nil)`
returns a `WorkEngine::Reconciler::Result` with:

- `source` and `captured_at`
- `snapshot` containing scoped Job, Workflow, Step, Run, SolidQueue,
  SpawnedProcess, worker heartbeat, workspace, main-health, and rate-limit
  evidence
- `issues`, an array of structured issue records

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
- `nonretryable_semantic_git_failure`

`safe_to_auto_repair` only describes whether a later repair planner may choose
an automatic action. This classifier itself is intentionally side-effect free.
