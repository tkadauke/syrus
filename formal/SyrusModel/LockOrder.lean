/-!
# DOC-44 concurrency: row locks follow one global order (counterexample)

"All code takes row locks in one global order, so lock cycles cannot
deadlock." M25 audited every multi-lock transaction over the engine models
and recorded which lock each one takes first. Those observations are the
edges of a "taken before, in the same transaction" graph. A cycle in that
graph means two transactions can each wait on the other. InnoDB then aborts
one with `ActiveRecord::Deadlocked`.

`observed` is that graph as the code stands. It has cycles
(`observed_has_cycle`):

- **Job ↔ Workflow.**
  - Job → Workflow: `Job#cancel_active_runs_and_close!` and the cancel/force
    paths, which go through `WorkflowCancellation`.
  - Workflow → Job: `LandingQueueProcessor#release_blocked_landing_slots!`;
    `TerminalWorkflowSync` called without a Job lock; `Workflow#start`'s
    `before { job.lock! }` when the caller holds the Workflow; and
    `record_run_failure!` on `auto_merge`.
- **Run ↔ Job.**
  - Run → Job: `RunJob#acquire_run_execution!`.
  - Job → Run: `PlannedExecutionOverrides::Operation`.
- **Run ↔ Workflow.**
  - Run → Workflow: the RepairExecutor requeue and `RepairQueueAffinity`.
  - Workflow → Run: `PlannedExecutionOverrides::Operation`.
- **Epic ↔ Job.**
  - Epic → Job: `MergeTrainDispatcher#try_dispatch!`.
  - Job → Epic: the merge-train rebuild in `RetryFailedStepEnqueuer`.

`proposed` is the order NY25 recommends:
AppSetting → Epic → Run → Job → WorkIntent → Workflow → Step → WorkUnit →
User. Every observed edge that agrees with it is kept, and each inverted one
is flipped, which is what fixing that site means. The result is acyclic
(`proposed_acyclic`; this holds by construction, since every edge then
follows a rank). The real content is `exactly_four_inversions`: under this
order exactly four observed edges are wrong, and each names the sites that
would change:

- Job → Run: `PlannedExecutionOverrides`, an operator path;
- Job → Epic: the merge-train rebuild in `RetryFailedStepEnqueuer`;
- Workflow → Job: landing slot release, `TerminalWorkflowSync` without a Job
  lock, `Workflow#start` under a held Workflow lock, and auto-merge
  `record_run_failure!`;
- Workflow → Run: `PlannedExecutionOverrides`.

The hot path, RunJob's Run → Job, keeps its order.

This file proves a property of the recorded graph, not of the code. The edges
come from the audit, whose evidence is in FINDINGS M25. A new lock site
changes the graph; that is the drift a lock-order check in CI would catch.
-/

namespace SyrusModel
namespace LockOrder

inductive Model where
  | appSetting
  | epic
  | job
  | workflow
  | step
  | run
  | workUnit
  | workIntent
  | user
deriving DecidableEq, Repr

open Model

def models : List Model := [appSetting, epic, job, workflow, step, run, workUnit, workIntent, user]

/-- "a is locked before b in the same transaction", as audited (M25). -/
def observed : List (Model × Model) :=
  [ (run, job), (run, workflow),
    (job, workflow), (job, step), (job, run), (job, workUnit), (job, workIntent), (job, epic), (job, user),
    (workflow, job), (workflow, step), (workflow, run), (workflow, workUnit), (workflow, user),
    (step, user),
    (workIntent, workflow), (workIntent, step), (workIntent, workUnit),
    (appSetting, workflow), (appSetting, step), (appSetting, user),
    (epic, job), (epic, workflow), (epic, step) ]

/-- Chosen to flip the fewest, and least hot, observed edges: RunJob takes the
Run first on every run, and WorkIntent sits between Job and Workflow. -/
def rank : Model → Nat
  | appSetting => 0 | epic => 1 | run => 2 | job => 3 | workIntent => 4
  | workflow => 5 | step => 6 | workUnit => 7 | user => 8

/-- Each observed edge, flipped where it runs against the proposed order. -/
def proposed : List (Model × Model) :=
  observed.map (fun (a, b) => if rank a < rank b then (a, b) else (b, a))

/-- Nodes reachable from `a` in at most `fuel` steps. -/
def reach (edges : List (Model × Model)) : Nat → Model → List Model
  | 0, _ => []
  | fuel + 1, a =>
    let next := (edges.filter (·.1 == a)).map (·.2)
    next ++ next.flatMap (reach edges fuel)

def hasCycle (edges : List (Model × Model)) : Bool :=
  models.any (fun m => (reach edges models.length m).contains m)

theorem observed_has_cycle : hasCycle observed = true := by native_decide

theorem proposed_acyclic : hasCycle proposed = false := by native_decide

/-- The sites to change: exactly these observed edges run against the order. -/
def inverted : List (Model × Model) := observed.filter (fun (a, b) => rank a > rank b)

theorem exactly_four_inversions :
    inverted = [(job, run), (job, epic), (workflow, job), (workflow, run)] := by native_decide

/-- The two-transaction witness: cancel (Job then Workflow) against the landing
queue's slot release (Workflow then Job). -/
theorem job_workflow_inversion :
    observed.contains (job, workflow) && observed.contains (workflow, job) = true := by native_decide

/-! ## Rows a transaction created itself (NY32)

The checker leaves out a lock on a row the locking transaction inserted. That
is sound because waiting needs another transaction to be able to see the row:
an uncommitted insert is visible only to its creator, so no other transaction
can lock it first, and its creator never waits for it. Such a lock adds no
edge to the wait-for graph, so it cannot close a cycle whatever the order.

Two transactions, and rows that are either committed or created by one of
them. -/
section SelfCreated

inductive Tx | t1 | t2
  deriving DecidableEq, Repr

def Tx.other : Tx → Tx
  | .t1 => .t2
  | .t2 => .t1

inductive RowOrigin | committed | createdBy (t : Tx)
  deriving DecidableEq, Repr

def visibleTo (origin : RowOrigin) (t : Tx) : Bool :=
  match origin with
  | .committed => true
  | .createdBy c => c == t

/-- `t` waits for a row exactly when it can see the row (it cannot ask for one
it cannot see) and the other transaction holds it, which needs the other
transaction to see it too. -/
def waitsFor (t : Tx) (origin : RowOrigin) (heldByOther : Bool) : Bool :=
  heldByOther && visibleTo origin t && visibleTo origin t.other

theorem self_created_never_waits (t : Tx) (held : Bool) :
    waitsFor t (.createdBy t) held = false := by
  cases t <;> cases held <;> decide

/-- Only committed rows can be waited on, so only they need the order. -/
theorem waits_only_on_committed_rows (t : Tx) (origin : RowOrigin) :
    waitsFor t origin true = true ↔ origin = .committed := by
  cases t <;> cases origin with
  | committed => decide
  | createdBy c => cases c <;> decide

end SelfCreated

end LockOrder
end SyrusModel
