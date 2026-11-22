/-!
# Who may hold the landing slot before the first Run (NY7, undecided)

The repository landing slot is the mutex every landing path checks.
`WorkUnit#block!` surrenders it only for an allowlist of reasons
(`EXTERNALLY_CLEARED_BLOCKED_REASONS`, and `urgent_job_active` before the first
Run). Any other block keeps it. When the block can last indefinitely, every
other approved Job in the repository starves for that long. A manual pause is
one example: it lasts until an operator lifts it. The coverage history records
three production starvations, each fixed by adding one more reason to the list.

The structural alternative: a landing blocked before its first Run never holds
the slot, whatever the reason. Resume already re-acquires a surrendered slot
before the unit becomes startable (`resume_for_workflow!`), so mutual exclusion
is unaffected. The cost is queue position.
-/

namespace SyrusModel
namespace PrestartSlot

inductive Reason where
  | externallyCleared | urgentActive | manualPause | admission | mainHealth
  deriving DecidableEq, Repr

/-- Indefinite: clears only on an operator or external action. -/
def indefinite : Reason → Bool
  | .externallyCleared | .manualPause => true
  | _ => false

/-- Today's allowlist. -/
def surrendersToday : Reason → Bool
  | .externallyCleared | .urgentActive => true
  | _ => false

/-- Option A: every pre-start block surrenders. -/
def surrendersA (_ : Reason) : Bool := true

/-- Starvation: an indefinite pre-start block keeps the slot. -/
def Starves (surrenders : Reason → Bool) : Prop := ∃ r, indefinite r = true ∧ surrenders r = false

instance (s : Reason → Bool) : Decidable (Starves s) := by
  unfold Starves
  exact decidable_of_iff (∃ r ∈ [Reason.externallyCleared, .urgentActive, .manualPause, .admission, .mainHealth],
      indefinite r = true ∧ s r = false)
    ⟨fun ⟨r, _, h⟩ => ⟨r, h⟩, fun ⟨r, h⟩ => ⟨r, by cases r <;> simp, h⟩⟩

theorem today_starves_on_manual_pause : Starves surrendersToday := ⟨.manualPause, rfl, rfl⟩

theorem option_a_never_starves : ¬ Starves surrendersA := by
  rintro ⟨r, _, h⟩; simp [surrendersA] at h

/-! ## After the first Run (NY27, decided A)

Once a landing has started, only `EXTERNALLY_CLEARED_BLOCKED_REASONS`
surrenders the slot. A manual pause was not in that list, so a started landing
paused by hand kept the slot until someone unpaused it. NY27 adds it, so no
indefinite block keeps the slot after the start either.

Unpause re-acquires the slot through `resume_for_workflow!`. If another
landing took it, `JobManualPause` leaves the unit queued without it, and the
next Run start takes it through `mark_running!`, deferred by `RunJob` while it
is held. Mutual exclusion is the lock's unique index (`LockSafety`).
-/

/-- After the first Run, before NY27: only the operator-cleared reasons. -/
def surrendersStartedBefore : Reason → Bool
  | .externallyCleared => true
  | _ => false

/-- After the first Run, with `manual_pause` in the allowlist. -/
def surrendersStartedAfter : Reason → Bool
  | .externallyCleared | .manualPause => true
  | _ => false

theorem started_before_starves_on_manual_pause : Starves surrendersStartedBefore := ⟨.manualPause, rfl, rfl⟩

theorem started_after_never_starves : ¬ Starves surrendersStartedAfter := by
  rintro ⟨r, hi, h⟩; cases r <;> simp_all [indefinite, surrendersStartedAfter]

end PrestartSlot
end SyrusModel
