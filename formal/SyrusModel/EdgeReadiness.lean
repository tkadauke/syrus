/-!
# A queued Step is resumed only once every dependency edge has settled

Derived from a recent main commit ("Make the chaos simulation's stranded step
genuinely resumable"). The chaos case expected the reconciler to resume a
Step whose linked-list predecessor had succeeded; the reconciler correctly
refused, because the Step was a fan-out successor still waiting on sibling
graders. The invariant: readiness follows dependency edges, not the
linked-list predecessor.

Two readiness checks exist and must agree:

* the reconciler's `queued_step_without_run` repair resumes a Step only when
  `StepDispatcher.deferred_phase_handoff_ready?` holds: with explicit edges,
  every dependency handed off (succeeded, skipped, or a superseded review
  cancellation) -- or, for a collector, `dependencies_settled?`; without
  edges, the predecessor handed off;
* the dispatcher starts a Step only when `Step#dependencies_settled?` holds:
  with explicit edges every dependency is terminal, otherwise the predecessor
  is.

Proved: the reconciler's readiness implies the dispatcher's
(`handoff_implies_settled`), so the reconciler never resumes a Step the
dispatcher would refuse to start on dependency grounds; and a finished
predecessor alone does not make a Step with explicit edges ready
(`predecessor_not_enough`), which is the chaos case. No bug found.
-/

namespace SyrusModel
namespace EdgeReadiness

inductive State where
  | queued | running | succeeded | failed | cancelled | skipped | blocked
  deriving DecidableEq, Repr

def State.terminal : State → Bool
  | .queued | .running => false
  | _ => true

structure Dep where
  state : State
  /-- `details["review_evidence_superseded"]` on a cancelled review. -/
  supersededReview : Bool
  deriving DecidableEq, Repr

/-- `StepDispatcher.handed_off_predecessor?` -/
def Dep.handedOff (d : Dep) : Bool :=
  d.state == .succeeded || d.state == .skipped || (d.state == .cancelled && d.supersededReview)

structure Step where
  /-- Explicit dependency edges (`depends_on_steps`). -/
  deps : List Dep
  /-- The linked-list predecessor (`previous_step`), if any. -/
  previous : Option Dep
  collector : Bool
  deriving DecidableEq, Repr

/-- `Step#dependencies_settled?` (no just-settled Step). -/
def settled (s : Step) : Bool :=
  if s.deps.isEmpty then
    match s.previous with
    | none => true
    | some p => p.state.terminal
  else s.deps.all (·.state.terminal)

/-- `StepDispatcher.deferred_phase_handoff_ready?` (for a queued Step). -/
def handoffReady (s : Step) : Bool :=
  if s.deps.isEmpty then
    match s.previous with
    | none => false
    | some p => p.handedOff
  else if s.collector then settled s
  else s.deps.all (·.handedOff)

theorem handedOff_terminal (d : Dep) (h : d.handedOff = true) : d.state.terminal = true := by
  obtain ⟨st, sr⟩ := d
  cases st <;> simp_all [Dep.handedOff, State.terminal]

/-- The reconciler resumes only what the dispatcher would start. -/
theorem handoff_implies_settled (s : Step) (h : handoffReady s = true) : settled s = true := by
  unfold handoffReady at h
  by_cases he : s.deps.isEmpty
  · simp only [he, if_true] at h
    unfold settled; simp only [he, if_true]
    cases hp : s.previous with
    | none => rfl
    | some p => rw [hp] at h; exact handedOff_terminal p h
  · simp only [he, if_false, Bool.false_eq_true] at h
    by_cases hc : s.collector
    · simp only [hc, if_true] at h; exact h
    · simp only [hc, if_false, Bool.false_eq_true] at h
      unfold settled; simp only [he, if_false, Bool.false_eq_true]
      rw [List.all_eq_true] at h ⊢
      intro d hd; exact handedOff_terminal d (h d hd)

/-- The chaos case: the predecessor (the last grader of a fan-out) succeeded,
    a sibling grader is still running, and the collector is not ready. -/
theorem predecessor_not_enough :
    let last : Dep := ⟨.succeeded, false⟩
    let sibling : Dep := ⟨.running, false⟩
    handoffReady ⟨[sibling, last], some last, true⟩ = false ∧
      settled ⟨[sibling, last], some last, true⟩ = false := by decide

end EdgeReadiness
end SyrusModel
