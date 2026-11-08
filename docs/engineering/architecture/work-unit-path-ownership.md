# WorkUnit path ownership

WorkUnit ownership is the current launch contract, not a rollout plan.
`WorkUnits::PathOwnership` assigns every supported entry path to one of three
ownership families. Callers resolve the path through that registry and launch
through `WorkUnits::Launcher`; compatibility fallbacks may explain old records
but do not form a second launch funnel.

| Path | Ownership family |
| --- | --- |
| `retry` | scheduler |
| `auto_retry_backoff` | scheduler |
| `resume` | scheduler |
| `manual_pause` | scheduler |
| `admission_control_pause` | scheduler |
| `provider_availability_pause` | scheduler |
| `auto_merge` | landing |
| `external_pr_merge` | landing |
| `landing_queue` | landing |
| `landing_validation` | landing |
| `merge_train` | landing |
| `merge_train_validation` | landing |
| `job_bundle` | landing |
| `job_bundle_validation` | landing |
| `stack_rebase` | landing |
| `epic_wide_workflow` | reconciler |
| `orphaned_queued_runs` | reconciler |
| `paused_units` | reconciler |
| `stale_runs` | reconciler |
| `terminal_orphan_workflows` | reconciler |
| `workflow_repair` | reconciler |

The exact membership is executable inventory, so
`app/services/work_units/path_ownership.rb` remains authoritative. The
architecture spec checks this table against that registry. Historical rollout
gates, legacy adapters, and graduation evidence remain in the completed plan;
they are not current implementation instructions.
