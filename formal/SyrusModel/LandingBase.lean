/-!
# DOC-44 Phase 3: landing never merges onto a base it could not check

`Steps::AutoMergeControl#defer_if_base_moved_since_validation!` runs right
before `Steps::AutoMerge` (and `Steps::ExternalPrMerge`) call GitHub's merge.
The landing graders validated the PR head rebased onto the base recorded by
the mergeability preflight (`job.mergeability_base_sha`). If the base branch
has moved since, GitHub's rebase merge would land commits that no grader ran
on, so the step defers (or rebases and continues) instead.

The check reads the live base head from GitHub. Before the fix, an error from
that read, or a blank answer, returned "base unchanged" and the merge went
ahead (`fail_open_on_error`). DOC-44: "Landing success implies an applicable
validation manifest for the content actually merged". The merge-train path
already fails closed on the same question (`ensure_base_unchanged!`).

A missing *validated* base (`validated = none`) still proceeds in both
versions: it is queued as a design question (NY10), since the preflight
always records the PR's base before the landing graders run.
-/

namespace SyrusModel
namespace LandingBase

/-- What reading the live base head returned. -/
inductive Observed where
  | sha (s : Nat)
  | blank
  | error
  deriving DecidableEq, Repr

inductive Decision where
  | merge
  | defer
  deriving DecidableEq, Repr

structure Input where
  validated : Option Nat
  observed : Observed
  deriving DecidableEq, Repr

/-- Before the fix: only a readable, different SHA defers. -/
def before (i : Input) : Decision :=
  match i.validated, i.observed with
  | some v, .sha c => if c == v then .merge else .defer
  | _, _ => .merge

/-- After the fix: a base that could not be read defers for a retry. -/
def after (i : Input) : Decision :=
  match i.validated, i.observed with
  | some v, .sha c => if c == v then .merge else .defer
  | some _, _ => .defer
  | none, _ => .merge

/-- The property: with a validated base, a merge happens only when the live
    base was read and equals it. -/
def baseConfirmed (i : Input) : Prop :=
  ∀ v, i.validated = some v → i.observed = .sha v

/-- Counterexample: a failed read merged anyway. -/
theorem fail_open_on_error : before ⟨some 1, .error⟩ = .merge ∧ ¬ baseConfirmed ⟨some 1, .error⟩ := by
  refine ⟨rfl, fun h => ?_⟩
  exact Observed.noConfusion (h 1 rfl)

theorem fail_open_on_blank : before ⟨some 1, .blank⟩ = .merge ∧ ¬ baseConfirmed ⟨some 1, .blank⟩ := by
  refine ⟨rfl, fun h => ?_⟩
  exact Observed.noConfusion (h 1 rfl)

/-- After the fix every merge with a validated base had that base confirmed. -/
theorem after_merge_confirms_base (i : Input) (h : after i = .merge) : baseConfirmed i := by
  intro v hv
  obtain ⟨val, obs⟩ := i
  simp only at hv
  subst hv
  cases obs with
  | sha c =>
    simp only [after] at h
    by_cases hc : c = v
    · subst hc; rfl
    · simp [hc] at h
  | blank => simp [after] at h
  | error => simp [after] at h

/-- The fix only turns merges into deferrals, and only for unreadable bases:
    every readable answer is decided exactly as before. -/
theorem after_differs_only_when_unread (i : Input) (h : after i ≠ before i) :
    i.validated.isSome ∧ (i.observed = .blank ∨ i.observed = .error) := by
  obtain ⟨val, obs⟩ := i
  cases val <;> cases obs <;> simp_all [after, before]

theorem after_never_adds_merges (i : Input) (h : after i = .merge) : before i = .merge := by
  obtain ⟨val, obs⟩ := i
  cases val <;> cases obs <;> simp_all [after, before]

end LandingBase
end SyrusModel
