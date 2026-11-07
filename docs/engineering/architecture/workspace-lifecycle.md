# Workspace lifecycle

## Mutable workflow workspace

`WorkflowWorkspace` creates the shared checkout at
`$SYRUS_DATA_ROOT/workflows/<workflow_id>/`. Most Steps in a Workflow operate
on that same checkout so implementation, repair, review, grading, and PR copy
observe one evolving branch. Workspace setup validates repository and branch
history and keeps credentials outside committed configuration.

The workspace belongs to the Workflow, not an individual Run. A Step failure
therefore must not delete it in an `ensure` block: later repair or diagnostic
Steps may need the same files. Terminal Workflow transitions schedule cleanup;
`WorkflowWorkspacePruneJob` sweeps retained terminal workspaces after the
retention period. See `app/services/workflow_workspace.rb` and
`app/jobs/workflow_workspace_prune_job.rb`. Supported operator behavior is in
[Workflow workspace lifecycle](../../../config/syrus_docs/workflow_workspace_lifecycle.md).

For one Job, retain the latest retryable or otherwise actionable Workflow
workspace and retire superseded sibling workspaces eagerly. “Keep the
workspace” applies to the active attempt, not to every historical attempt.

## Immutable distributed work

Distributed graders do not read the mutable checkout. A
`WorkflowSourceSnapshot` records the revision and source metadata. Workers
create detached immutable checkouts from that snapshot and can reuse prepared
dependency layers keyed by preparation plan and worker capabilities. Snapshot
creation, checkout, and cleanup live under `app/services/workflow_source_*`
and the distributed grader services; their specs are the exact file map.

Never infer that a grader saw uncommitted or later workspace changes. Publish a
new snapshot when the source changes.

Earlier design documents left snapshot identity, materialization, and cleanup
as open questions. The first-class `WorkflowSourceSnapshot` record and detached
checkout are the implemented answers; those questions are historical, not
current uncertainty.

## Placement

`PlannedExecutionRequirement` records project, target, source, and explicit
capabilities. Supported capability dimensions are `os`, `arch`, `toolchain`,
and `runtime`; `os` is `linux` or `macos`. Workers advertise configured and
locally probed capabilities. `RunQueueResolver` either selects an eligible
worker/queue or blocks the Run with `no_capable_worker`.

Proposal and workflow tooling must declare required capabilities explicitly;
placement is not inferred from prompt prose. `.syrus.yml` project and target
metadata may narrow requirements for a specific target.

## Chat and preview workspaces

Chat workspaces and preview child processes also live on their owning worker,
not the web process. Access is proxied through worker-aware services. Their
lifecycle is separate from Workflow cleanup; see
[Chat and sidecars](chat-and-sidecars.md) and the workspace pitfalls in
[Workspace and execution](../pitfalls/workspace-and-execution.md).
