/-!
# DOC-44 Phase 3: a landing override is one decision about one blocker

An operator can override one landing-queue blocker once
(`LandingBlockerOverride`, granted by the app API or the
`override_landing_blocker_once` pending action). The grant checks that the
blocker is the Job's current one and overridable. The queue then lets the Job
through a blocker the override *matches*
(`LandingQueueProcessor#landing_blocker_override_matches?`) and marks the
override used once it actually unblocks a landing.

DOC-44: "Overrides apply only to explicitly overrideable blockers and one
intended decision"; "Stale overrides cannot bypass a changed blocker".

The match compared the blocker *key* only. An override stays until it is used,
so one granted for one instance of a blocker (this Job's CI repair, these
inherited checks, that urgent Job) that was never needed bypassed a later,
different instance under the same key (`stale_override_bypasses`).

After the fix the override records the blocker's parameters when granted and
matches only that exact blocker.
-/

namespace SyrusModel
namespace LandingOverride

structure Blocker where
  key : Nat
  params : List Nat
  deriving DecidableEq, Repr

structure Override where
  key : Nat
  /-- Recorded at grant time; `none` before the fix existed. -/
  params : Option (List Nat)
  used : Bool
  deriving DecidableEq, Repr

def overridable (nonOverridable : List Nat) (b : Blocker) : Bool := !nonOverridable.contains b.key

def matchesBefore (non : List Nat) (o : Override) (b : Blocker) : Bool :=
  overridable non b && !o.used && o.key == b.key

def matchesAfter (non : List Nat) (o : Override) (b : Blocker) : Bool :=
  overridable non b && !o.used && o.key == b.key && o.params == some b.params

/-- What the operator decided about: the blocker current at grant time. -/
def grant (b : Blocker) : Override := ⟨b.key, some b.params, false⟩

/-- The counterexample: an override granted for one CI repair (Job 1) bypasses
    another (Job 2) under the same key. -/
theorem stale_override_bypasses :
    matchesBefore [] (grant ⟨7, [1]⟩) ⟨7, [2]⟩ = true ∧ (⟨7, [2]⟩ : Blocker) ≠ ⟨7, [1]⟩ := by decide

/-- After the fix an override only ever bypasses the blocker it was granted
    for. -/
theorem after_only_granted (non : List Nat) (g b : Blocker) (h : matchesAfter non (grant g) b = true) : b = g := by
  simp only [matchesAfter, grant, Bool.and_eq_true, beq_iff_eq, Option.some.injEq] at h
  obtain ⟨⟨⟨_, _⟩, hk⟩, hp⟩ := h
  cases g; cases b; simp_all

/-- Non-overridable blockers stay non-overridable, and a used override bypasses
    nothing. -/
theorem after_respects_gates (non : List Nat) (o : Override) (b : Blocker) (h : matchesAfter non o b = true) :
    !non.contains b.key ∧ o.used = false := by
  simp only [matchesAfter, overridable, Bool.and_eq_true, Bool.not_eq_true'] at h
  exact ⟨by simpa using h.1.1.1, h.1.1.2⟩

/-- The fix only narrows: whatever it lets through, the key-only match did too. -/
theorem after_narrows (non : List Nat) (o : Override) (b : Blocker) (h : matchesAfter non o b = true) :
    matchesBefore non o b = true := by
  simp only [matchesAfter, matchesBefore, Bool.and_eq_true] at h ⊢
  exact h.1

end LandingOverride
end SyrusModel
