/-!
# An unpublished stacked Job whose work conflicts with its restacked parent (NY29, decided A)

`pr_open` replays a stacked Job's finished work onto its parent's live head.
Before NY29 a conflicting replay was reported as `awaiting_stable_base`, which
is retryable, and every retry ran the same mechanical replay. A conflict that
is a property of the two trees, not of timing, conflicts again, so the retries
could only burn the budget (`before_never_publishes`).

After NY29 the conflict fails `pr_open` with `stack_base_rebase_conflict`,
and the Try branch runs `stack_base_agent_rebase`, the validation loop, and
one plain `pr_open`. A conflict the agent resolves publishes
(`after_resolved_publishes`), and every path ends within two `pr_open`
attempts (`after_terminates`): the trailing `pr_open` is plain, so with F105 it
cannot expand the branch again.

The model is one run of the recovery. `persistent` says whether the replay
conflicts whenever it runs; `agentResolves` and `validates` are the agent's and
the validation loop's outcomes; `parentMovesAgain` says whether the parent
moves into a fresh conflict before the trailing `pr_open`.
-/

namespace SyrusModel
namespace StackConflictRecovery

inductive Outcome where
  | published | failedFinal | budgetExhausted
  deriving DecidableEq, Repr

structure World where
  agentResolves : Bool
  validates : Bool
  parentMovesAgain : Bool
  deriving DecidableEq, Repr

/-- Before: each retry replays the same conflicting rebase. -/
def before (retries : Nat) : Outcome × Nat :=
  (.budgetExhausted, retries + 1)

/-- After: one agent resolution, then one plain pr_open. Returns the outcome
and the number of pr_open attempts. -/
def after (w : World) : Outcome × Nat :=
  if !w.agentResolves then (.failedFinal, 1)
  else if !w.validates then (.failedFinal, 1)
  else if w.parentMovesAgain then (.failedFinal, 2)
  else (.published, 2)

def worlds : List World :=
  [true, false].flatMap fun a => [true, false].flatMap fun v => [true, false].map fun p => ⟨a, v, p⟩

theorem before_never_publishes : ∀ r ∈ [0, 1, 2, 3, 5, 10], (before r).1 ≠ .published := by decide

theorem after_resolved_publishes : after ⟨true, true, false⟩ = (.published, 2) := by decide

theorem after_terminates : ∀ w ∈ worlds, (after w).2 ≤ 2 ∧ (after w).1 ≠ .budgetExhausted := by decide

end StackConflictRecovery
end SyrusModel
