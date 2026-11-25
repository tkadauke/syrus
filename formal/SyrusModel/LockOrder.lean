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

**Superseded (NY40).** The enforced order is now the hierarchy, parents before
children: AppSetting, User, Epic, Job, WorkIntent, WorkUnit, Workflow, Step,
Run (`hierRank` below). Transactions take a record's ancestry first through
`Lineage.lock_all!`, and every sequence it can take is in that order
(`lock_all_in_order`). The NY25 order and its proofs below are the record of
how the observed graph was made acyclic first.

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

/-- A lock request either waits for a holder or, with NOWAIT (NY36), fails at
once. `waitsForReq` is whether the request can wait. -/
def waitsForReq (nowait : Bool) (t : Tx) (origin : RowOrigin) (heldByOther : Bool) : Bool :=
  !nowait && waitsFor t origin heldByOther

/-- A NOWAIT request never waits, so it adds no edge to the wait-for graph and
cannot close a cycle, whatever the transaction holds or locks next. This is
why the provider reservation's User lock is outside the order. -/
theorem nowait_never_waits (t : Tx) (origin : RowOrigin) (held : Bool) :
    waitsForReq true t origin held = false := by
  simp [waitsForReq]

/-- An ordinary request on a committed row the other transaction holds waits. -/
theorem blocking_request_waits (t : Tx) : waitsForReq false t .committed true = true := by
  cases t <;> decide

end SelfCreated

/-! ## A pending Job closure inside a cancellation (NY33)

Cancelling Workflow A locks A's Steps (`cancel_active_descendants!`), then
applies A's pending Job closure, which cancels the Job's other Workflows. The
first `rank`-decreasing step in a transaction's lock sequence is an inversion.
`JobClosure.lock_pending_workflows!` takes those Workflows first. -/

/-- No lock in the sequence ranks below one taken before it. -/
def monotone : List Model → Bool
  | a :: b :: rest => rank a ≤ rank b && monotone (b :: rest)
  | _ => true

/-- Before: A, A's Steps, then sibling B (and B's Steps). -/
def closureCascadeBefore : List Model := [ workflow, step, workflow, step ]

/-- After: A, the closure's Workflows, then every Step. Same-model locks are
in id order among themselves. -/
def closureCascadeAfter : List Model := [ workflow, workflow, step, step ]

theorem closure_cascade_before_inverts : monotone closureCascadeBefore = false := by decide

theorem closure_cascade_after_in_order : monotone closureCascadeAfter = true := by decide

/-! ## The hierarchical target order (NY40)

The order is moving to the hierarchy, parents before children:
AppSetting, User, Epic, Job, WorkIntent, WorkUnit, Workflow, Step, Run.
`Lineage.lock_all!` (`app/services/lineage.rb`) locks the ancestries of
several records at once. It walks `Lineage::MODELS` top down and locks every
row of a model, in id order, before the next model. So the models it locks are
always a sublist of `lineageModels`, whichever rows the records name. -/

def hierRank : Model → Nat
  | appSetting => 0 | user => 1 | epic => 2 | job => 3 | workIntent => 4
  | workUnit => 5 | workflow => 6 | step => 7 | run => 8

def monotoneH : List Model → Bool
  | a :: b :: rest => hierRank a ≤ hierRank b && monotoneH (b :: rest)
  | _ => true

/-- Every sublist of a list (each element kept or dropped, order preserved). -/
def subs : List Model → List (List Model)
  | [] => [ [] ]
  | a :: rest => (subs rest).map (a :: ·) ++ subs rest

/-- `Lineage::MODELS`, in the order `lock_all!` walks them. -/
def lineageModels : List Model := [ epic, job, workIntent, workUnit, workflow, step, run ]

set_option maxRecDepth 20000 in
/-- Every sequence `lock_all!` can take is in the hierarchical order: it locks
some sublist of `lineageModels`, whichever records it is given. -/
theorem lock_all_in_order : ∀ s ∈ subs lineageModels, monotoneH s = true := by decide

/-- The pending-closure cascade before NY40: the sibling Workflows were locked
first, then cancelling each one locked its ancestry (Job, intent, WorkUnit). -/
def closureLineageBefore : List Model := [ workflow, workflow, job, workIntent, workUnit ]

/-- After: `JobClosure.lock_pending_workflows!` passes this Workflow and the
siblings to `lock_all!`, so every ancestor comes first; the Steps follow. -/
def closureLineageAfter : List Model := [ job, workIntent, workUnit, workflow, workflow, step, step ]

theorem closure_lineage_before_inverts : monotoneH closureLineageBefore = false := by decide

theorem closure_lineage_after_in_order : monotoneH closureLineageAfter = true := by decide

/-- The models the closure's `lock_all!` takes are one of those sublists. -/
theorem closure_lineage_after_from_lock_all :
    [ job, workIntent, workUnit, workflow ] ∈ subs lineageModels := by decide

end LockOrder
end SyrusModel
