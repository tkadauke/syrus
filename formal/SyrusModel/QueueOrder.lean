/-!
# Landing queue order

`LandingQueueProcessor#call` walks a repository's landing units in queue order
(priority, then approval time, then dependencies) and lands the first eligible
unit whose landing slot is free. Blocked units do not hold the queue: they are
passed over. So the order property is "a unit lands only if every unit ahead
of it in the same slot is blocked".

`LandingQueueProcessor.try_land!(job)` is the inline door: approval,
auto-approval and mergeability refreshes call it so a ready Job lands without
waiting for the next tick. Before the fix it checked only the Job's own
blockage. A Job approved while an older or higher-priority Job had just become
eligible, before the next tick, took the slot ahead of it
(`tryLand_before_jumps`).

After the fix `try_land!` lands its Job only when no earlier unit of the same
slot is eligible, and otherwise runs the ordered pass, so both doors pick the
same unit (`tryLand_after_agrees`).
-/

namespace SyrusModel
namespace QueueOrder

/-- A queue of landing units in order; `true` = eligible. Units are indexed by
    position. -/
abbrev Queue := List Bool

/-- The ordered pass: the first eligible unit. -/
def firstEligible : Queue → Option Nat
  | [] => none
  | e :: rest => if e then some 0 else (firstEligible rest).map (· + 1)

def eligibleAt (q : Queue) (i : Nat) : Bool := q.getD i false

/-- `try_land!(job)` before the fix: the Job lands if it is itself eligible. -/
def tryLandBefore (q : Queue) (i : Nat) : Option Nat := if eligibleAt q i then some i else none

/-- After the fix: an eligible Job defers to the ordered pass. -/
def tryLandAfter (q : Queue) (i : Nat) : Option Nat := if eligibleAt q i then firstEligible q else none

/-- Order: whatever lands, no earlier unit was eligible. -/
def InOrder (q : Queue) (pick : Option Nat) : Prop :=
  ∀ k, pick = some k → ∀ j < k, eligibleAt q j = false

theorem tryLand_before_jumps : ¬ InOrder [true, true] (tryLandBefore [true, true] 1) := by
  intro h
  have := h 1 rfl 0 (by decide)
  simp [eligibleAt] at this

theorem firstEligible_in_order : ∀ q : Queue, InOrder q (firstEligible q)
  | [], k, h => by simp [firstEligible] at h
  | e :: rest, k, h => by
    intro j hj
    cases e with
    | true => simp [firstEligible] at h; omega
    | false =>
      simp only [firstEligible, Bool.false_eq_true, if_false, Option.map_eq_some_iff] at h
      obtain ⟨k', hk', rfl⟩ := h
      cases j with
      | zero => rfl
      | succ j =>
        have := firstEligible_in_order rest k' hk' j (by omega)
        simpa [eligibleAt] using this

theorem tryLand_after_in_order (q : Queue) (i : Nat) : InOrder q (tryLandAfter q i) := by
  unfold tryLandAfter
  split
  · exact firstEligible_in_order q
  · intro k h; simp at h

/-- Both doors pick the same unit whenever the inline door picks anything. -/
theorem tryLand_after_agrees (q : Queue) (i : Nat) (k : Nat) (h : tryLandAfter q i = some k) :
    firstEligible q = some k := by
  unfold tryLandAfter at h
  split at h
  · exact h
  · simp at h

theorem firstEligible_eligible : ∀ (q : Queue) (i : Nat), firstEligible q = some i → eligibleAt q i = true
  | [], i, h => by simp [firstEligible] at h
  | e :: rest, i, h => by
    cases e with
    | true => simp [firstEligible] at h; subst h; rfl
    | false =>
      simp only [firstEligible, Bool.false_eq_true, if_false, Option.map_eq_some_iff] at h
      obtain ⟨k', hk', rfl⟩ := h
      simpa [eligibleAt] using firstEligible_eligible rest k' hk'

/-- The inline door still lands its own Job when it is first in line. -/
theorem tryLand_after_lands_front (q : Queue) (i : Nat) (h : firstEligible q = some i) :
    tryLandAfter q i = some i := by
  simp [tryLandAfter, firstEligible_eligible q i h, h]

end QueueOrder
end SyrusModel
