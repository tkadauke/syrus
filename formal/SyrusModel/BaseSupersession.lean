/-!
# A CI repair waiting on its base is cancelled exactly when main moved past it

Derived from a recent main commit ("Cancel a running CI repair whose base main
health has moved past"). A CI repair held before `analyze_and_fix` until its
base is known healthy can wait forever once main moves on, because main health
only grades the branch head. The commit cancels it when
`WorkUnits::Gates::CiRepairSafety.base_superseded_for?` finds a health check of
another SHA after the repair began waiting.

Two invariants:

* liveness: once the branch head is some other commit and the poller observes
  it after the repair began waiting, the repair is released
  (`after_live`);
* safety: the repair is cancelled only on an observation of a branch head
  other than its base (`after_safe`).

The commit's rule counted *any* health check of another SHA. Main grading
records its result for the commit it graded, with `checked_at` set to when the
grade finished, and records `"unknown"` when the SHA is missing. A slow grade
of an older commit that finishes after a newer base landed and its CI repair
began waiting cancelled a repair whose base was the current head
(`late_grade_cancels`). Restricted now to head observations: CI polls (the
poller only polls the head) and grades of the head the poller last recorded.

Model: observations carry the SHA, the source, whether that SHA was the branch
head when observed (true for CI polls by construction), and whether they
happened after the repair began waiting.
-/

namespace SyrusModel
namespace BaseSupersession

inductive Source where | ciPoll | graderWorkflow deriving DecidableEq, Repr

structure Obs where
  /-- `none` is a grade recorded as "unknown". -/
  sha : Option Nat
  source : Source
  afterSince : Bool
  /-- The SHA was the branch head when observed. -/
  wasHead : Bool
  deriving DecidableEq, Repr

/-- The poller only polls the branch head. -/
def Obs.Wellformed (o : Obs) : Prop := o.source = .ciPoll → o.wasHead = true

def other (base : Nat) (o : Obs) : Bool := o.sha != some base

def before (base : Nat) (obs : List Obs) : Bool :=
  obs.any (fun o => other base o && o.afterSince)

/-- `trackedHead`: `repository.last_health_checked_sha`, the head the poller
    last recorded; a grade of it is a head observation. -/
def after (base : Nat) (trackedHead : Option Nat) (obs : List Obs) : Bool :=
  obs.any (fun o => other base o && o.sha.isSome && o.afterSince &&
    (o.source == .ciPoll || (o.sha.isSome && o.sha == trackedHead)))

theorem late_grade_cancels :
    before 2 [⟨some 1, .graderWorkflow, true, false⟩] = true ∧
      after 2 (some 2) [⟨some 1, .graderWorkflow, true, false⟩] = false := by decide

/-- Liveness: a CI poll of another head after the repair began waiting
    releases it. -/
theorem after_live (base h : Nat) (hne : h ≠ base) (tracked : Option Nat) (obs : List Obs)
    (hp : ⟨some h, .ciPoll, true, true⟩ ∈ obs) : after base tracked obs = true :=
  List.any_eq_true.mpr ⟨_, hp, by simp [other, hne]⟩

/-- Safety: a cancellation always rests on an observation, after the repair
    began waiting, of a known SHA other than the base that was either polled
    as the head or is the head the poller tracks. -/
theorem after_safe (base : Nat) (tracked : Option Nat) (obs : List Obs)
    (h : after base tracked obs = true) :
    ∃ o ∈ obs, ∃ s, o.sha = some s ∧ s ≠ base ∧ o.afterSince = true ∧
      (o.source = .ciPoll ∨ tracked = some s) := by
  obtain ⟨o, ho, hx⟩ := List.any_eq_true.mp h
  obtain ⟨sha, src, aft, wh⟩ := o
  cases sha with
  | none => simp at hx
  | some s =>
    refine ⟨_, ho, s, rfl, ?_, ?_, ?_⟩
    · intro hsb; subst hsb; simp [other] at hx
    · simp only [Bool.and_eq_true] at hx; exact hx.1.2
    · cases src with
      | ciPoll => exact Or.inl rfl
      | graderWorkflow =>
        right
        simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq] at hx
        rcases hx.2 with hc | ⟨_, ht⟩
        · exact absurd hc (by decide)
        · exact ht.symm

/-- The fix only narrows the commit's rule. -/
theorem after_narrows (base : Nat) (tracked : Option Nat) (obs : List Obs)
    (h : after base tracked obs = true) : before base obs = true := by
  obtain ⟨o, ho, hx⟩ := List.any_eq_true.mp h
  simp only [Bool.and_eq_true] at hx
  exact List.any_eq_true.mpr ⟨o, ho, by simp [hx.1.1.1, hx.1.2]⟩

end BaseSupersession
end SyrusModel
