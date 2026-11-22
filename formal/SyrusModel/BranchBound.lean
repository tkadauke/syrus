/-!
# A Try branch's recovery is bounded by its nesting

`Workflows::MergeTrain.merge_train_land_with_rebase_recovery` bounds base-move
recovery by nesting: attempt `i < k` is a Try whose branch ends in attempt
`i + 1`, and attempt `k` is a plain Step. Each failure of a Try Step expands
its branch once (`try_branch_expanded`).

`StepDispatcher#try_node_for` matched a Step without a `try_id` to *any* Try
of its kind. The plain Step at depth `k` has no `try_id` and shares its kind
with the Trys at depths `1..k-1`, so it matched one and expanded again, and
every Step that expansion inserted ends in another plain Step of the same kind:
recovery was unbounded. F105 marks plain branch Steps, and a marked Step
never matches a Try.

The model: a Step is a Try at depth `d` or a plain Step. A failure of a Step
that matches a Try inserts a fresh copy of that Try's branch, whose last Step is
the next depth down (or plain at the bottom).
-/

namespace SyrusModel
namespace BranchBound

inductive StepNode where
  | tryAt (depth : Nat)
  | plain
  deriving DecidableEq, Repr

/-- The last Step of the branch a Try at depth `d` inserts, with `k` attempts. -/
def branchTail (k d : Nat) : StepNode :=
  if d + 1 < k then .tryAt (d + 1) else .plain

/-- Which Try a failed Step expands, if any. `matchesAnyTry` is the old
fallback for a Step without a try_id. -/
def expands (matchesAnyTry : Bool) (k : Nat) : StepNode → Option Nat
  | .tryAt d => some d
  | .plain => if matchesAnyTry && decide (1 < k) then some 1 else none

/-- Expansions when the last Step of every inserted branch fails, with fuel. -/
def expansions (matchesAnyTry : Bool) (k : Nat) : Nat → StepNode → Nat
  | 0, _ => 0
  | fuel + 1, s =>
    match expands matchesAnyTry k s with
    | some d => expansions matchesAnyTry k fuel (branchTail k d) + 1
    | none => 0

/-- Fixed: from the top Try, recovery expands exactly `k` times. -/
theorem fixed_bounded : ∀ k ∈ [1, 2, 3, 4], expansions false k 50 (.tryAt 0) = k := by decide

/-- Before: with two or more attempts, recovery uses up all the fuel. -/
theorem before_unbounded : ∀ k ∈ [2, 3, 4], expansions true k 50 (.tryAt 0) = 50 := by decide

end BranchBound
end SyrusModel
