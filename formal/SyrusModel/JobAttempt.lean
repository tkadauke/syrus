/-!
# Only the Job's current attempt decides its state

`Workflows::JobLifecyclePropagation#fail!` ignores a failed Workflow when a
newer Workflow is active on the Job; `#cancel!` did not, so cancelling an older
Workflow (for any non-superseding reason) marked a Job failed while a newer
Workflow was working on it. Job-scoped work cannot overlap (the WorkUnit lock,
`LockSafety`), but Epic-scoped Workflows that use the Job as their
representative can.

Workflows are numbered by creation order; `active w` means its WorkUnit is
active.
-/

namespace SyrusModel
namespace JobAttempt

inductive J where | running | failed deriving DecidableEq, Repr
inductive Outcome where | failed | cancelled deriving DecidableEq, Repr

structure S (n : Nat) where
  job : J
  active : Fin n → Bool

variable {n : Nat}

def newerActive (s : S n) (w : Fin n) : Bool := (List.finRange n).any fun v => w < v && s.active v

/-- Workflow `w` finishes with outcome `o`; `guarded o` says whether that
    outcome's propagation checks for a newer active attempt. -/
def finish (guarded : Outcome → Bool) (s : S n) (w : Fin n) (o : Outcome) : S n :=
  let s' : S n := { s with active := fun v => if v = w then false else s.active v }
  if guarded o && newerActive s' w then s' else { s' with job := .failed }

def before : Outcome → Bool | .failed => true | .cancelled => false
def after : Outcome → Bool | _ => true

/-- A running Job some active Workflow still works on. -/
def worked (s : S n) : Bool := s.job = .running && (List.finRange n).any s.active

/-- Old: cancelling the older Workflow fails a Job the newer one is running. -/
theorem old_cancel_fails_worked_job :
    let s : S 2 := ⟨.running, fun _ => true⟩
    worked s = true ∧ (finish before s 0 .cancelled).job = .failed ∧
      ((finish before s 0 .cancelled).active 1) = true := by decide

/-- Fixed: an older Workflow's terminal outcome never fails a Job that a newer
    Workflow is still working on, for any outcome. -/
theorem older_outcome_keeps_job (s : S n) (w : Fin n) (o : Outcome)
    (h : newerActive { s with active := fun v => if v = w then false else s.active v } w = true) :
    (finish after s w o).job = s.job := by
  simp only [finish, after, Bool.true_and, h, ite_true]

end JobAttempt
end SyrusModel
