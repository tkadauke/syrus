# Core domain and workflow map

| Concern | Primary locations |
| --- | --- |
| Job/Epic lifecycle | `app/models/job.rb`, `app/models/epic.rb`, `app/models/job/`, `app/models/epic/` |
| Workflow/Step/Run | `app/models/workflow.rb`, `app/models/step.rb`, `app/models/run.rb` |
| Kind registries | `app/models/job/kind.rb`, `app/models/workflow/trigger_kind.rb`, `app/models/step/kind.rb` |
| Work engine records | `app/models/work_intent.rb`, `app/models/work_unit.rb`, `app/models/work_unit_lock.rb`, `app/models/work_unit_member.rb` |
| Work definitions | `app/services/work_definitions/` |
| Work launch/ownership | `app/services/work_units/`, `app/services/work_units/path_ownership.rb` |
| Reconciliation | `app/services/work_engine/reconciler.rb` |
| Workflow templates | `app/services/workflows/` |
| Step handlers | `app/services/steps/` |
| Dispatch | `app/services/step_dispatcher.rb`, `app/jobs/run_job.rb` |
| Workspace | `app/services/workflow_workspace.rb`, `app/jobs/workflow_workspace_prune_job.rb` |
| Source snapshots | `app/models/workflow_source_snapshot.rb`, distributed grader services under `app/services/` |
| Agent providers | `app/services/agent_providers/`, invocation services under `app/services/` |
| Landing/rebase | `app/services/landing_queue/`, landing and rebase WorkDefinitions/Steps |
| Polling | `app/jobs/poll_all_*`, `app/jobs/poll_*` |
| Access control | `app/policies/`, `app/models/repository_membership.rb`, `app/models/team.rb` |

See [Domain model and work engine](../architecture/domain-model-and-work-engine.md)
and [Workflow execution](../architecture/workflow-execution.md) for behavior.
