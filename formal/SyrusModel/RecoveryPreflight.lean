/-!
# Recovery preflight blocks on unknown compatibility (NY22, decided A)

`LocalBackups::Recovery::Preflight` issues the restore token only when no check
fails, and a restore needs that token. It failed on a known mismatch but only
warned when a compatibility fact was missing, so a restore could replace the
database of a destination whose compatibility was never established.

Now each unknown fails unless the operator passes the flag named after that
unknown (`--allow-unknown-<code>`), and then it is a warning.
-/

namespace SyrusModel
namespace RecoveryPreflight

inductive Unknown where
  | databaseAdapter | databaseVersion | applicationVersion | applicationCompatibility | encryptionFingerprints
  deriving DecidableEq, Repr

def allUnknowns : List Unknown :=
  [.databaseAdapter, .databaseVersion, .applicationVersion, .applicationCompatibility, .encryptionFingerprints]

/-- Before: an unknown never failed. -/
def failsBefore (_present : Unknown → Bool) (_accepted : Unknown → Bool) (_u : Unknown) : Bool := false

/-- After: an unknown that is present fails unless that exact code is accepted. -/
def fails (present accepted : Unknown → Bool) (u : Unknown) : Bool := present u && !accepted u

/-- Ready: no check fails (known mismatches are left out of the model). -/
def ready (present accepted : Unknown → Bool) : Bool := allUnknowns.all fun u => !fails present accepted u

/-- Before: a preflight with every fact unknown and nothing accepted was ready. -/
theorem before_ready_with_unknowns :
    (allUnknowns.all fun u => !failsBefore (fun _ => true) (fun _ => false) u) = true := by decide

/-- After: ready implies every unknown present was accepted. -/
theorem ready_implies_accepted (present accepted : Unknown → Bool) (h : ready present accepted = true) :
    ∀ u ∈ allUnknowns, present u = true → accepted u = true := by
  intro u hu hp
  unfold ready at h
  have := List.all_eq_true.mp h u hu
  simp [fails, hp] at this
  exact this

/-- After: accepting one unknown does not excuse another. -/
theorem one_flag_excuses_one :
    ∀ u ∈ allUnknowns, ∀ v ∈ allUnknowns, u ≠ v →
      fails (fun w => w == u || w == v) (fun w => w == u) v = true := by decide

end RecoveryPreflight
end SyrusModel
