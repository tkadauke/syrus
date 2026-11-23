/-!
# Self-scheduled wakeups are bounded without approval (NY34, decided B)

Main's `11d8bc436c` made `schedule_wakeup` essential: it never asks. Each wakeup
starts a paid agent turn, and that turn could schedule the next one, so nothing
bounded a chat that kept waking itself. NY34 bounds the chain instead:

* a turn that a wakeup started may schedule at most one follow-up;
* a chain longer than `limit` wakeups, each scheduled by the previous one's
  turn, with no human message in between, is refused, and the agent asks.

`Mcp::Tools::ScheduleWakeupTool#chain_refusal` enforces both. Each wakeup
records `chain_depth` (1 when a human turn scheduled it) and `source_wakeup_id`.

This file proves, for any `limit`:

1. `depth_bounded`: every wakeup the tool creates has depth at most `limit`.
2. `one_child`: a wakeup has at most one follow-up.
3. `chain_length_bounded`: so the wakeups descending from one human turn's
   wakeup form a single path of at most `limit` turns.
-/

namespace SyrusModel
namespace WakeupChain

/-- Who started the turn that calls `schedule_wakeup`. -/
inductive Origin
  | human
  | wakeup (depth : Nat) (hasChild : Bool)

/-- The tool's decision: the new wakeup's depth, or a refusal. -/
def schedule (limit : Nat) : Origin → Option Nat
  | .human => some 1
  | .wakeup depth hasChild =>
    if hasChild then none
    else if depth < limit then some (depth + 1)
    else none

theorem depth_bounded (limit : Nat) (hl : 1 ≤ limit) (o : Origin) (d : Nat)
    (hsrc : ∀ depth hasChild, o = .wakeup depth hasChild → depth ≤ limit)
    (h : schedule limit o = some d) : d ≤ limit := by
  cases o with
  | human => simp [schedule] at h; omega
  | wakeup depth hasChild =>
    have := hsrc depth hasChild rfl
    cases hasChild <;> simp [schedule] at h
    · obtain ⟨hlt, rfl⟩ := h
      omega

theorem one_child (limit depth : Nat) : schedule limit (.wakeup depth true) = none := by
  simp [schedule]

/-- A chain started by a human turn: each step is the follow-up the previous
wakeup's turn scheduled (it had none yet, since it may have only one). -/
def chainDepths (limit : Nat) : Nat → Nat → List Nat
  | 0, _ => []
  | fuel + 1, depth =>
    match schedule limit (.wakeup depth false) with
    | some next => next :: chainDepths limit fuel next
    | none => []

theorem chain_from (limit fuel depth : Nat) :
    (chainDepths limit fuel depth).length ≤ limit - depth := by
  induction fuel generalizing depth with
  | zero => simp [chainDepths]
  | succ fuel ih =>
    simp only [chainDepths, schedule]
    by_cases h : depth < limit
    · simp [h]
      have := ih (depth + 1)
      omega
    · simp [h]

/-- The human turn's wakeup has depth 1 and its follow-ups extend it, so the
whole chain from one human message is at most `limit` wakeups. -/
theorem chain_length_bounded (limit fuel : Nat) :
    1 + (chainDepths limit fuel 1).length ≤ max limit 1 := by
  have := chain_from limit fuel 1
  omega

/-- The default the operator chose. -/
theorem default_chain : (chainDepths 100 1000 1).length = 99 := by decide

end WakeupChain
end SyrusModel
