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

end PrestartSlot
end SyrusModel
