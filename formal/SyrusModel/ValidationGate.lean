/-!
# DOC-44 Phase 3: the landing validation gate accepts only current, required, conclusive evidence

`LandingValidationManifest.verify` and `.evidence_for` (`app/services/
landing_validation_manifest.rb`) decide whether the commit about to be merged
(`AutoMerge` and `MergeTrainLand` call `.gate`) is backed by validation. The
model keeps what the decision reads: the manifest's head SHA and binding, and
per target whether it is required, its typed outcome, the SHA its source
snapshot was taken at (if any) and whether it carries command/environment
fingerprints.

Proved, for every manifest (DOC-44, "Validation evidence and artifact
provenance"):

* `ok_has_required`: advisory evidence cannot replace required evidence; a
  manifest with no required result never passes.
* `ok_required_passed`: every required result passed with fingerprints, or is
  a test failure that `grader_collect`'s rung-zero adjudication or an
  exact-evidence outcome override accepted, held to the same fingerprint and
  SHA rules; infrastructure failure, inconclusive,
  cancelled or missing results never pass (`infra_never_passes` names the
  case), and an unaccepted test failure never passes
  (`unaccepted_failure_never_passes`).
* `ok_exact_current`: with exact-head binding, the manifest and every required
  result that ran from a snapshot are for the landing SHA itself.
* `evidenceFor_ok_current`: the gate consults only a manifest recorded for (or,
  by the operator-trusted clean-rebase carry-forward, re-bound to) the landing
  SHA; evidence for any other SHA, even with the same tree, blocks.

Reused results (`carried_forward`, `target_health`) carry no source SHA, so the
gate cannot SHA-check them; their binding to the landing SHA is the fanout's
fingerprint comparison (`TargetHealthReuse`, `partition_*`), which this model
treats as an assumption, not a guarantee (`reused_not_sha_checked`).

No bug found.
-/

namespace SyrusModel
namespace ValidationGate

inductive Outcome where
  | passed | testFailed | inconclusive | infrastructureFailed | cancelled | missing
  deriving DecidableEq, Repr

inductive Binding where
  | exactHead | cleanRebaseCarryForward
  deriving DecidableEq, Repr

structure Target where
  required : Bool
  outcome : Outcome
  /-- `source_sha` of a target that ran from a source snapshot. -/
  sourceSha : Option Nat
  hasEvidence : Bool
  /-- The collect's adjudicator or an exact-evidence outcome override accepted this failure. -/
  accepted : Bool := false
  deriving DecidableEq, Repr

structure Manifest where
  head : Nat
  binding : Binding
  /-- `source_snapshot.source_sha`. -/
  snapshot : Option Nat
  targets : List Target
  deriving DecidableEq, Repr

/-- `target_blockers` is empty. -/
def targetOk (expected : Nat) (b : Binding) (t : Target) : Bool :=
  let current :=
    (match b, t.sourceSha with
     | .exactHead, some s => s == expected
     | _, _ => true) && t.hasEvidence
  match t.outcome with
  | .passed => current
  | .testFailed => t.accepted && current
  | _ => false

/-- `verify(manifest, expected_sha:)`.ok? (the CI-phase blockers only add
    blockers, so leaving them out over-approximates acceptance). -/
def verify (expected : Nat) (m : Manifest) : Bool :=
  (m.binding != .exactHead || m.head == expected) &&
  (match m.binding, m.snapshot with
   | .exactHead, some s => s == expected
   | _, _ => true) &&
  (m.targets.filter (·.required)).length > 0 &&
  (m.targets.filter (·.required)).all (targetOk expected m.binding)

/-- `evidence_for`: the newest manifest recorded for exactly `sha`; any other
    manifest only yields a `sha_mismatch` blocker. -/
def evidenceFor (sha : Nat) (manifests : List Manifest) : Bool :=
  match manifests.find? (·.head == sha) with
  | some m => verify sha m
  | none => false

theorem ok_has_required {e : Nat} {m : Manifest} (h : verify e m = true) :
    ∃ t ∈ m.targets, t.required = true := by
  simp only [verify, Bool.and_eq_true, decide_eq_true_eq] at h
  obtain ⟨⟨⟨_, _⟩, hl⟩, _⟩ := h
  obtain ⟨t, ht⟩ := List.exists_mem_of_length_pos hl
  exact ⟨t, (List.mem_filter.mp ht).1, by simpa using (List.mem_filter.mp ht).2⟩

theorem ok_required_passed {e : Nat} {m : Manifest} (h : verify e m = true) :
    ∀ t ∈ m.targets, t.required = true →
      (t.outcome = .passed ∨ (t.outcome = .testFailed ∧ t.accepted = true)) ∧ t.hasEvidence = true := by
  intro t ht hr
  simp only [verify, Bool.and_eq_true, List.all_eq_true] at h
  have hk := h.2 t (List.mem_filter.mpr ⟨ht, by simpa using hr⟩)
  unfold targetOk at hk
  cases ho : t.outcome <;> simp_all

theorem infra_never_passes (e : Nat) (m : Manifest) (t : Target) (ht : t ∈ m.targets)
    (hr : t.required = true) (hi : t.outcome = .infrastructureFailed) : verify e m = false := by
  cases hv : verify e m
  · rfl
  · have := (ok_required_passed hv t ht hr).1
    rw [hi] at this
    rcases this with h | ⟨h, _⟩ <;> exact Outcome.noConfusion h

theorem unaccepted_failure_never_passes (e : Nat) (m : Manifest) (t : Target) (ht : t ∈ m.targets)
    (hr : t.required = true) (hf : t.outcome = .testFailed) (ha : t.accepted = false) : verify e m = false := by
  cases hv : verify e m
  · rfl
  · have := (ok_required_passed hv t ht hr).1
    rw [hf] at this
    rcases this with h | ⟨_, h⟩
    · exact Outcome.noConfusion h
    · rw [ha] at h; exact Bool.noConfusion h

theorem ok_exact_current {e : Nat} {m : Manifest} (h : verify e m = true) (hb : m.binding = .exactHead) :
    m.head = e ∧ (∀ s, m.snapshot = some s → s = e) ∧
      ∀ t ∈ m.targets, t.required = true → ∀ s, t.sourceSha = some s → s = e := by
  simp only [verify, Bool.and_eq_true, List.all_eq_true, hb] at h
  obtain ⟨⟨⟨hh, hs⟩, _⟩, ha⟩ := h
  refine ⟨by simpa using hh, ?_, ?_⟩
  · intro s hsn; rw [hsn] at hs; simpa using hs
  · intro t ht hr s hts
    have hk := ha t (List.mem_filter.mpr ⟨ht, by simpa using hr⟩)
    unfold targetOk at hk
    cases ho : t.outcome <;> simp_all

theorem evidenceFor_ok_current {sha : Nat} {ms : List Manifest} (h : evidenceFor sha ms = true) :
    ∃ m ∈ ms, m.head = sha ∧ verify sha m = true := by
  unfold evidenceFor at h
  cases hf : ms.find? (·.head == sha) with
  | none => simp [hf] at h
  | some m =>
    rw [hf] at h
    exact ⟨m, List.mem_of_find?_eq_some hf, by simpa using List.find?_some hf, h⟩

/-- Evidence for another SHA blocks even when nothing else is wrong with it. -/
example : evidenceFor 2 [⟨1, .exactHead, some 1, [⟨true, .passed, some 1, true, false⟩]⟩] = false := by decide

/-- An advisory pass does not stand in for a missing required result. -/
example : verify 1 ⟨1, .exactHead, none, [⟨false, .passed, some 1, true, false⟩]⟩ = false := by decide

/-- A required result that passed on an earlier SHA blocks under exact binding. -/
example : verify 2 ⟨2, .exactHead, none, [⟨true, .passed, some 1, true, false⟩]⟩ = false := by decide

/-- The trust boundary: a reused result has no source SHA, so the gate accepts
    it on its fingerprints alone. Its applicability to this SHA is decided
    upstream by the fanout's fingerprint comparison. -/
theorem reused_not_sha_checked :
    verify 2 ⟨2, .exactHead, none, [⟨true, .passed, none, true, false⟩]⟩ = true := by decide

end ValidationGate
end SyrusModel
