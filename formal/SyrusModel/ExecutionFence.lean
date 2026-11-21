/-!
# Fencing Run execution with an attempt counter (decided NY3: A)

A worker that looks dead (stale heartbeat) has its Run requeued; another worker
may claim it. If the first worker was only stalled, it resumes. Before the fix
its liveness checkpoint (`ensure_run_still_active!`) refused only *terminal*
records, so a requeued Run (queued) or a reclaimed one (running again) let it
carry on: commit, push, call GitHub -- two executors' side effects on one Run.

The fix: every claim increments `execution_attempt`; an executor remembers the
value it claimed; the checkpoint refuses unless the Run is running at that same
attempt.
-/

namespace SyrusModel
namespace ExecutionFence

inductive RState where
  | queued | running | terminal
  deriving DecidableEq, Repr

structure Row where
  state : RState
  attempt : Nat
  deriving DecidableEq, Repr

/-- A claim: queued → running, attempt + 1. -/
def claim (r : Row) : Row := { state := .running, attempt := r.attempt + 1 }
/-- Recovery: a running Run back to queued. -/
def requeue (r : Row) : Row := { r with state := .queued }

/-- The checkpoint before. -/
def passesBefore (r : Row) (_claimed : Nat) : Bool := r.state ≠ .terminal
/-- The checkpoint after. -/
def passesAfter (r : Row) (claimed : Nat) : Bool := r.state = .running && r.attempt = claimed

/-- Executor A claims, stalls; recovery requeues; B claims. -/
def afterTakeover : Row := claim (requeue (claim ⟨.queued, 0⟩))
def aClaimed : Nat := (claim ⟨.queued, 0⟩).attempt
def bClaimed : Nat := afterTakeover.attempt

/-- Before: the stalled executor A still passes once B owns the Run... -/
theorem before_stale_passes : passesBefore afterTakeover aClaimed = true := by decide
/-- ...and even while the Run sits requeued and unowned. -/
theorem before_requeued_passes : passesBefore (requeue (claim ⟨.queued, 0⟩)) aClaimed = true := by decide

/-- After: A is stopped in both situations, and B passes. -/
theorem after_stale_stopped : passesAfter afterTakeover aClaimed = false := by decide
theorem after_requeued_stopped : passesAfter (requeue (claim ⟨.queued, 0⟩)) aClaimed = false := by decide
theorem after_owner_passes : passesAfter afterTakeover bClaimed = true := by decide

/-- In general at most one claimant passes: two different claimed values cannot
    both match the row. -/
theorem at_most_one_passes (r : Row) (a b : Nat) (ha : passesAfter r a = true)
    (hb : passesAfter r b = true) : a = b := by
  simp [passesAfter] at ha hb
  omega

end ExecutionFence
end SyrusModel
