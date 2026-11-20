import SyrusModel.Reconciler

/-!
# Counterexamples

Concrete, `decide`-checked worlds showing where an operation does not preserve
a property *unless its caller guarantees a precondition*, or where the
reconciler's outcome depends on repair order. Each one is a lead to check
against the Ruby callers, not automatically a production bug.
-/

namespace SyrusModel
namespace Examples

open World

def mkUnit {nI nU nK : Nat} (i : Fin nI) (s : UnitState)
    (workflow : Option Nat := some 1) (needs : Fin nK → Bool := fun _ => true)
    (reason : Reason := .none) (parent : Option (Fin nU) := none) : WUnit nI nU nK :=
  { intent := i, state := s, reason := reason, workflow := workflow,
    workflowTerminal := false, parent := parent, needs := needs, enforced := true }

/-! ### 1. Finished units are re-entrant (by design)

`block!`, `unblock!`, `mark_running!` and `mark_terminal!` have no guard on the
unit's current state. Called on a finished unit they reopen its intent and
make it active again, or overwrite its outcome.

This is intentional: a retry reuses the same WorkUnit and calls
`mark_running!` on it (see the comment in `WorkUnits::WorkflowLifecycle#started!`).
So "a finished outcome is never rewritten" is **not** an invariant of the
lifecycle methods. Only `preempt!` guarantees it (`preempt_keeps_outcomes`),
which is the case that matters: a late preemption cannot clobber a success.
The examples pin down exactly what re-entry does. -/

/-- One succeeded unit whose intent is satisfied. -/
def finished : World 1 1 1 :=
  { intent := fun _ => .satisfied
    unit := fun _ => mkUnit 0 .succeeded
    holder := fun _ => none
    landing := fun _ => false }

example : finished.Inv := by decide

/-- `block!` on a succeeded unit: it becomes `blocked` and its satisfied intent
    is re-requested. -/
example : ¬ finished.OutcomesKept (finished.block 0 .ordinary) := by decide
example : (finished.block 0 .ordinary).intent 0 = .requested := by decide

/-- `mark_running!` on a succeeded unit re-acquires its locks and runs it again. -/
example : (finished.markRunning 0).map (fun w => ((w.unit 0).state, w.holder 0, w.intent 0))
    = some (.running, some 0, .requested) := by decide

/-- `mark_terminal!(:cancelled)` on a succeeded unit overwrites the outcome. -/
example : (finished.markTerminal 0 .cancelled).map (fun w => (w.unit 0).state) = some .cancelled := by decide

/-! ### 2. Shared-runtime lock skipping can break mutual exclusion

`ensure_active_locks!` *skips* a key already held by a same-runtime owner (same
`workflow_id`) instead of co-owning it. If that owner then finishes, it releases
the key while the other unit is still running, and an unrelated unit can take
it. Requires two WorkUnits on one Workflow: `Workflow has_one :work_unit` and
`Launcher#instantiate` creates one unit per Workflow, but the schema's index on
`work_units.workflow_id` is not unique. `LockSafety.steps_lock_safe` proves this
is the *only* way: with one unit per Workflow, mutual exclusion holds. -/

/-- Units 0 and 1 share workflow 7; unit 2 is unrelated (workflow 9). All need key 0. -/
def shared : World 1 3 1 :=
  { intent := fun _ => .requested
    unit := fun u => match u.val with
      | 0 => mkUnit 0 .running (workflow := some 7)
      | 1 => mkUnit 0 .queued (workflow := some 7)
      | _ => mkUnit 0 .queued (workflow := some 9)
    holder := fun _ => some 0
    landing := fun _ => true }

example : shared.Inv ∧ shared.RunningHoldsLocks := by decide

/-- Unit 1 starts: it skips key 0 (same owner), does not hold it, and runs. -/
def sharedStep1 : World 1 3 1 := (shared.markRunning 1).getD shared
example : (sharedStep1.unit 1).state = .running ∧ sharedStep1.holder 0 = some 0 := by decide

/-- Unit 0 succeeds and releases key 0; unit 1 keeps running without it. -/
def sharedStep2 : World 1 3 1 := (sharedStep1.markTerminal 0 .succeeded).getD sharedStep1
example : sharedStep2.Inv ∧ ¬ sharedStep2.RunningHoldsLocks := by decide

/-- The unrelated unit 2 now acquires key 0 — two different runtimes both
    running work that needs the same exclusive key. -/
def sharedStep3 : World 1 3 1 := (sharedStep2.markRunning 2).getD sharedStep2
example : (sharedStep3.unit 1).state = .running ∧ (sharedStep3.unit 2).state = .running ∧
    sharedStep3.holder 0 = some 2 ∧ sharedStep3.sameOwner 1 2 = false := by decide

/-! ### 3. Intent outcome depends on repair order

An open intent with one succeeded and one failed unit (and no active unit)
triggers both `satisfy_work_intent_from_succeeded_work_unit` and
`fail_work_intent_from_failed_work_unit`. Whichever runs first wins; the other
then skips. Ruby runs the succeeded classifier first, so success always wins,
regardless of which attempt was more recent. -/

def mixed : World 1 2 1 :=
  { intent := fun _ => .requested
    unit := fun u => if u.val = 0 then mkUnit 0 .succeeded else mkUnit 0 .failed
    holder := fun _ => none
    landing := fun _ => false }

example : mixed.succeededUnsatisfied 0 ∧ mixed.failedUnfailed 1 := by decide
example : ((mixed.satisfyFromSucceeded 0).failFromFailed 1).intent 0 = .satisfied := by decide
example : ((mixed.failFromFailed 1).satisfyFromSucceeded 0).intent 0 = .failed := by decide

/-! ### 4. A globally quiescent world with an orphaned requested intent

`cancel_active_work_unit_without_workflow` cancels with reason
`missing_workflow`, which is not superseding, so `TerminalUnitSync` leaves the
intent `requested` ("so the Intent can be scheduled again"). The only
classifiers that relaunch a requested intent run solely when the reconcile is
scoped to that `work_intent_id`, so an unscoped reconcile sees nothing left to
do. Relaunch then depends entirely on some other path (e.g. `JobWakeup` for a
job-scoped intent of a runnable Job). -/

def noWorkflow : World 1 1 1 :=
  { intent := fun _ => .requested
    unit := fun _ => mkUnit 0 .queued (workflow := none)
    holder := fun _ => none
    landing := fun _ => false }

example : noWorkflow.activeWithoutWorkflow 0 := by decide
example : (noWorkflow.cancelWithoutWorkflow 0).globalQuiescent ∧
    (noWorkflow.cancelWithoutWorkflow 0).requestedWithoutActiveUnit 0 := by decide

end Examples
end SyrusModel
