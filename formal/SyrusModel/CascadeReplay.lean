/-!
# Recovering a lost Step-failure cascade (NY26, decided A)

When a Step fails, `StepDispatcher#fail!` decides what that means:

* advance, for kinds whose remediation is `:advance`;
* the next loop iteration, for `:retry_step`;
* otherwise an in-place infrastructure retry, if the last Run was classified
  retryable, the Step has at most `INFRASTRUCTURE_STEP_RETRY_LIMIT` Runs, and
  `Runs::RepeatedFailure.stop_in_place?` does not hold (the rerun failed
  exactly like the Run before it, or the Job's shared identical-failure budget
  is spent -- `repeated` below; RetryTermination.lean bounds that budget)
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

Since main's 10876221e8, a retry after a `provider_transient` failure reopens the
Step and schedules its Run after a backoff instead of creating it at once. The
limit is still checked first, and the Step can only fail again once that Run
exists and fails, so each replay round still adds exactly one Run before the next
can start: `step` below is unchanged.
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
  /-- `Runs::RepeatedFailure.stop_in_place?` on the Step's latest Run. -/
  repeated : Bool
  deriving DecidableEq, Repr

def limit : Nat := 2

/-- `StepDispatcher#fail!`. -/
def dispatch (i : Input) : Outcome :=
  match i.remediation with
  | .advance => .advance
  | .retryStep => .loopIteration
  | .none =>
    if i.retryable && decide (i.runs ≤ limit) && !i.repeated then .infraRetry
    else if i.tryBranch then .tryBranch
    else .hardFail

/-- The repair before NY26: `Workflow#fail!`. -/
def repairBefore (_ : Input) : Outcome := .hardFail

/-- The repair after NY26: `StepDispatcher.fail_from(failed_step)`. -/
def repairAfter (i : Input) : Outcome := dispatch i

theorem repair_after_agrees (i : Input) : repairAfter i = dispatch i := rfl

theorem repair_before_diverges :
    repairBefore ⟨.none, true, 1, false, false⟩ ≠ dispatch ⟨.none, true, 1, false, false⟩ := by decide

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
    ∀ r ∈ [1, 2, 3], ∀ b ∈ [true, false], ∀ t ∈ [true, false], ∀ p ∈ [true, false],
      rounds 10 ⟨.none, b, r, t, p⟩ ≤ limit ∧ step ⟨.none, b, limit + 1, t, p⟩ = none := by
  decide

/-- A rerun that repeated the previous Run's failure is never rerun in place
again: the cascade falls through to a try branch or a hard fail, and the
auto-retry ladder's fresh Workflow is the next remediation. -/
theorem repeated_never_reruns (i : Input) (h : i.repeated = true) : dispatch i ≠ .infraRetry := by
  cases i with
  | mk rem b r t p =>
    simp only at h; subst h
    cases rem <;> simp [dispatch] <;> split <;> simp

end CascadeReplay
end SyrusModel
