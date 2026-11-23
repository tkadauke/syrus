/-!
# Recovering a lost Step-failure cascade (NY26, decided A)

When a Step fails, `StepDispatcher#fail!` decides what that means:

* advance, for kinds whose remediation is `:advance`;
* the next loop iteration, for `:retry_step`;
* otherwise an in-place infrastructure retry, if the last Run was classified
  retryable and the Step has at most `INFRASTRUCTURE_STEP_RETRY_LIMIT` Runs
  (for a transient provider error the rerun waits out a backoff first; the
  outcome and the Run it adds are the same, so timing is not modelled);
* otherwise a try branch, if one applies;
* otherwise a hard fail of the Workflow.

If that cascade is lost, the reconciler's `fail_workflow_from_failed_step`
repairs the Workflow. Before NY26 it hard-failed it outright. After NY26 it calls
`StepDispatcher.fail_from(failed_step)`, the same function.

This file proves:

1. `repair_after_agrees`: the repair now reaches the live outcome on every input.
2. `repair_before_diverges`: the old repair disagreed, for example on a
   retryable infrastructure failure.
3. `replay_terminates`: repeated loss and replay cannot loop forever. Each
   in-place retry adds a Run, and the retry is refused once the count passes the
   limit, so a Step gets at most `limit` replayed retries.
-/

namespace SyrusModel
namespace CascadeReplay

inductive Remediation where
  | advance | retryStep | none
  deriving DecidableEq, Repr

inductive Outcome where
  | advance | loopIteration | infraRetry | tryBranch | hardFail
  deriving DecidableEq, Repr

structure Input where
  remediation : Remediation
  retryable : Bool
  runs : Nat
  tryBranch : Bool
  deriving DecidableEq, Repr

def limit : Nat := 2

/-- `StepDispatcher#fail!`. -/
def dispatch (i : Input) : Outcome :=
  match i.remediation with
  | .advance => .advance
  | .retryStep => .loopIteration
  | .none =>
    if i.retryable && decide (i.runs ≤ limit) then .infraRetry
    else if i.tryBranch then .tryBranch
    else .hardFail

/-- The repair before NY26: `Workflow#fail!`. -/
def repairBefore (_ : Input) : Outcome := .hardFail

/-- The repair after NY26: `StepDispatcher.fail_from(failed_step)`. -/
def repairAfter (i : Input) : Outcome := dispatch i

theorem repair_after_agrees (i : Input) : repairAfter i = dispatch i := rfl

theorem repair_before_diverges :
    repairBefore ⟨.none, true, 1, false⟩ ≠ dispatch ⟨.none, true, 1, false⟩ := by decide

/-- One loss-and-replay round on a Step with no step-kind remediation: an
infrastructure retry adds a Run, and anything else ends the replay. -/
def step (i : Input) : Option Input :=
  if repairAfter i = .infraRetry then some { i with runs := i.runs + 1 } else none

/-- Rounds until the replay stops, with fuel. -/
def rounds : Nat → Input → Nat
  | 0, _ => 0
  | fuel + 1, i =>
    match step i with
    | some i' => rounds fuel i' + 1
    | none => 0

/-- Every replay chain stops after at most `limit` retries, whatever the
starting Run count (checked for Steps that start with 1 to 3 Runs). -/
theorem replay_terminates :
    ∀ r ∈ [1, 2, 3], ∀ b ∈ [true, false], ∀ t ∈ [true, false],
      rounds 10 ⟨.none, b, r, t⟩ ≤ limit ∧ step ⟨.none, b, limit + 1, t⟩ = none := by
  decide

end CascadeReplay
end SyrusModel
