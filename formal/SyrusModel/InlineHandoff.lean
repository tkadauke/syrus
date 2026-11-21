/-!
# Inline drive: every held Run is driven or handed back

While a RunJob drives a Workflow, `Run#enqueue_run_job` does not enqueue the
Runs the dispatcher creates for that Workflow: the driver is to run its
successor itself. The driver runs at most one of them. Before the fix the rest
had no queue job at all -- the reconciler re-enqueued ~15 a day, each about two
minutes late -- and a driver yielding on SIGTERM left even its chosen successor
"to be re-enqueued by the reaper".

The model: a driver step creates `held` Runs; the driver then picks at most one
(`pick`) and may be shutting down. A Run is *owned* when it has a queue job or
it is the Run this driver will run next.
-/

namespace SyrusModel
namespace InlineHandoff

structure StepEnd where
  held : List Nat
  pick : Option Nat
  shutdown : Bool
  deriving DecidableEq, Repr

/-- The Run the driver will run next. -/
def driven (s : StepEnd) : Option Nat := if s.shutdown then none else s.pick

/-- Before: nothing is enqueued at the step boundary. -/
def enqueuedBefore (_ : StepEnd) : List Nat := []

/-- After: every held Run except the one driven is handed back. -/
def enqueuedAfter (s : StepEnd) : List Nat := s.held.filter (fun r => some r ≠ driven s)

def owned (enqueued : StepEnd → List Nat) (s : StepEnd) (r : Nat) : Prop :=
  r ∈ enqueued s ∨ driven s = some r

/-- Every held Run is owned. -/
def AllOwned (enqueued : StepEnd → List Nat) : Prop :=
  ∀ s r, r ∈ s.held → owned enqueued s r

/-- No Run is both queued and driven (no duplicate execution). -/
def NoDouble (enqueued : StepEnd → List Nat) : Prop :=
  ∀ s r, r ∈ enqueued s → driven s ≠ some r

theorem before_loses : ¬ AllOwned enqueuedBefore := by
  intro h
  have := h ⟨[1, 2], some 1, false⟩ 2 (by decide)
  simp [owned, enqueuedBefore, driven] at this

theorem before_loses_on_shutdown : ¬ AllOwned enqueuedBefore := by
  intro h
  have := h ⟨[1], some 1, true⟩ 1 (by decide)
  simp [owned, enqueuedBefore, driven] at this

theorem after_all_owned : AllOwned enqueuedAfter := by
  intro s r hr
  unfold owned enqueuedAfter
  by_cases hd : driven s = some r
  · exact Or.inr hd
  · left
    exact List.mem_filter.mpr ⟨hr, by
      simp only [ne_eq, decide_not, Bool.not_eq_true', decide_eq_false_iff_not]
      exact fun h => hd h.symm⟩

theorem after_no_double : NoDouble enqueuedAfter := by
  intro s r hr hd
  unfold enqueuedAfter at hr
  have := (List.mem_filter.mp hr).2
  simp [hd] at this

end InlineHandoff
end SyrusModel
