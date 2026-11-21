/-!
# DOC-44 Phase 3: validation reuse requires every correctness-relevant identity to match

DOC-44: "Validation reuse requires identical correctness-relevant identity";
"Cache reuse is permitted only when every correctness-relevant identity
matches".

`LandingValidationCache.reusable_for?` reuses an earlier green landing
validation for the same head (or the same tree) when `stale_reason` finds
nothing wrong. The identities it compares: base ref, base SHA (or an equal base
tree), the required-grader configuration fingerprint and the changed-file
selection fingerprint.

The two fingerprints already failed closed both ways: cached but not current,
or current but not cached. Base ref and base SHA were compared only when the
*current* value was known. When the PR payload carried no base, a validation
recorded against one base was reused for an unknown one
(`unknown_base_reused`).

Model: per identity, the cached and current values (`none` = not known). A
recorded identity must be matched by a known, equal current one. For the base
SHA an equal base tree also counts. A cached identity that is missing is
tolerated only where the code allows it (legacy exact-head entries for base
ref and SHA).
-/

namespace SyrusModel
namespace ValidationReuse

structure Field where
  cached : Option Nat
  current : Option Nat
  /-- An entry without this identity may still be reused (legacy exact-head). -/
  missingCachedAllowed : Bool
  deriving DecidableEq, Repr

/-- `stale_reason` before the fix, for base ref / base SHA: compared only
    when the current value is known. -/
def okBefore (f : Field) : Bool :=
  match f.current, f.cached with
  | none, _ => true
  | some _, none => f.missingCachedAllowed
  | some c, some k => c == k

/-- After the fix (and as the fingerprints always were). -/
def okAfter (f : Field) : Bool :=
  match f.current, f.cached with
  | none, none => true
  | none, some _ => false
  | some _, none => f.missingCachedAllowed
  | some c, some k => c == k

def reusable (ok : Field → Bool) (fields : List Field) : Bool := fields.all ok

theorem unknown_base_reused :
    reusable okBefore [⟨some 1, none, true⟩] = true ∧ reusable okAfter [⟨some 1, none, true⟩] = false := by decide

/-- After the fix, every identity the validation recorded is matched by an
    equal, known current one. -/
theorem okAfter_sound (f : Field) (h : okAfter f = true) : ∀ k, f.cached = some k → f.current = some k := by
  intro k hk
  obtain ⟨cached, current, allowed⟩ := f
  simp only at hk
  subst hk
  cases current with
  | none => simp [okAfter] at h
  | some c =>
    simp only [okAfter, beq_iff_eq] at h
    rw [h]

theorem reusable_sound (fields : List Field) (h : reusable okAfter fields = true) :
    ∀ f ∈ fields, ∀ k, f.cached = some k → f.current = some k := by
  intro f hf
  exact okAfter_sound f (List.all_eq_true.mp h f hf)

/-- The fix only refuses more. -/
theorem after_narrows (f : Field) (h : okAfter f = true) : okBefore f = true := by
  obtain ⟨cached, current, allowed⟩ := f
  cases current <;> cases cached <;> simp_all [okAfter, okBefore]

end ValidationReuse
end SyrusModel
