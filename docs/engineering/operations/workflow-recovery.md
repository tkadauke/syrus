# Workflow recovery

## Diagnose before retrying

Read the Job, WorkIntent, WorkUnit and locks, Workflow, current Step and Run,
plus the failure artifact and worker heartbeat. Decide which layer owns the
blockage:

| Symptom | First owner to inspect |
| --- | --- |
| no Workflow launched | WorkIntent, WorkUnit, definition, and locks |
| Workflow queued, no Run | StepDispatcher and transition callbacks |
| Run queued | queue consumption, gates, and capability placement |
| Run running, worker absent | stale-run reaper and worker heartbeat |
| grader sees old source | WorkflowSourceSnapshot, not live workspace |
| terminal Workflow retains files | cleanup scheduling and prune job |
| landing cannot proceed | landing WorkUnit, mergeability, and base movement |

Do not create a second Workflow merely because the first looks quiet. Confirm
the launch owner and idempotency key first.

For supported UI and chat repair actions, consult
[Admin recovery](../../../config/syrus_docs/admin_recovery.md); this page owns
the internal diagnosis model rather than duplicating operator instructions.

## Normal recovery paths

Operator retry, resume, pause, auto-merge, merge-train, and stack-rebase actions
go through `WorkUnits::PathOwnership` and the corresponding WorkDefinition.
`WorkEngine::Reconciler` repairs WorkIntent/WorkUnit ownership before falling
through to workflow repair. Use these services or the supported UI/API action;
do not update state columns by hand.

`ReapStaleRunsJob` handles Runs whose executing worker disappeared or whose
heartbeat is stale. It can fail an orphaned running Run and re-enqueue a queued
successor that was stranded after inline Step advancement. It is not a normal
dispatcher and should not be invoked as a generic retry mechanism.

## Workspace and source recovery

A live Workflow's mutable workspace may be required by later repair Steps.
Avoid deleting it while the Workflow is active. Terminal cleanup is scheduled
from lifecycle transitions, and `WorkflowWorkspacePruneJob` handles retained
terminal directories. If a worker died with a workspace, first determine
whether ownership can be resumed or the workflow must retry from a durable
source.

Distributed graders recover from their recorded `WorkflowSourceSnapshot`; they
must not silently switch to the current mutable branch. A failed snapshot
checkout should fail/block that distributed attempt and follow its cleanup
contract.

## Verify recovery

Confirm that one owning WorkUnit is active, its locks are coherent, the intended
Workflow/Run was created or resumed, an eligible live worker claimed it, and
the prior failure code cleared or was superseded. Continue through the next
meaningful transition rather than considering an enqueued row proof of repair.
