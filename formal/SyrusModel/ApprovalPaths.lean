/-!
# Approval eligibility follows Job lifecycle state

Approval availability is determined by the Job lifecycle state, independently
of active Runs, WorkUnits, feedback, rebases, visual review activity, or PR
checks. Those signals remain landing gates. GitHub review ingestion uses the
same state rule and never promotes a running Job to implemented merely because
an approving review exists.

**Invariant `RuntimeIndependent`:** for a fixed lifecycle state, changing
runtime activity cannot change the result of an approval path.
-/

namespace SyrusModel
namespace ApprovalPaths

inductive JS where
  | queued | running | implemented | approved
  deriving DecidableEq, Repr

structure Job where
  state : JS
  runtimeActive : Bool
  feedbackActive : Bool
  checksPassing : Bool
  deriving DecidableEq, Repr

/-- `approve!` and every approval entry point: implemented state is the gate. -/
def approve (j : Job) : Job :=
  if j.state = .implemented then { j with state := .approved } else j

def RuntimeIndependent (path : Job → Job) : Prop :=
  ∀ j activity feedback checks,
    (path {
      state := j.state
      runtimeActive := activity
      feedbackActive := feedback
      checksPassing := checks
    }).state = (path j).state

theorem approve_runtime_independent : RuntimeIndependent approve := by
  intro j activity feedback checks
  by_cases h : j.state = .implemented <;> simp [approve, h]

theorem implemented_approves_regardless_of_runtime
    (activity feedback checks : Bool) :
    (approve {
      state := .implemented,
      runtimeActive := activity,
      feedbackActive := feedback,
      checksPassing := checks
    }).state = .approved := by
  simp [approve]

theorem nonimplemented_never_promoted
    (j : Job) (h : j.state ≠ .implemented) :
    (approve j).state = j.state := by
  simp [approve, h]

end ApprovalPaths
end SyrusModel
