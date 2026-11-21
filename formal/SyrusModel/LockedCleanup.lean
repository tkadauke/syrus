/-!
# Terminal cleanup must decide under the lock a reopen holds

`cancel_terminal_workflow_active_descendants` checked "the Workflow is
terminal" and then cancelled its queued/running descendants. Retry-from-failed-
step reopens the same Workflow (failed → running) and queues fresh Runs while
holding the Job lock. Unlocked, the reopen can land between the check and the
cancel, and the retry's work is cancelled under a running Workflow. Production:
a failed initial Workflow's grader tail was cancelled at the same second a retry
re-dispatched it; four of the retry's Runs survived only because they were
already running.

The model: two processes over one shared state. The cleanup is `check; cancel`
(two steps unlocked, one atomic step locked); the retry is one atomic reopen.
-/

namespace SyrusModel
namespace LockedCleanup

structure W where
  terminal : Bool
  /-- The tail holds live work the current attempt needs. -/
  liveTail : Bool
  /-- Live work was cancelled while the Workflow was running. -/
  damaged : Bool
  deriving DecidableEq, Repr

def reopen (w : W) : W := { w with terminal := false, liveTail := true }

/-- The cancel step, given what the check saw. -/
def cancel (sawTerminal : Bool) (w : W) : W :=
  if sawTerminal then { w with liveTail := false, damaged := w.damaged || !w.terminal } else w

/-- Unlocked: check, then the retry may interleave, then cancel. -/
def unlockedInterleaved (w : W) : W :=
  let saw := w.terminal
  cancel saw (reopen w)

/-- Locked: the check and the cancel are one step; the retry runs before or after. -/
def lockedBefore (w : W) : W := reopen (cancel w.terminal w)
def lockedAfter (w : W) : W := let w' := reopen w; cancel w'.terminal w'

def failed : W := { terminal := true, liveTail := false, damaged := false }

/-- Before: the interleaving cancels the retry's live work under a running Workflow. -/
theorem unlocked_damages : (unlockedInterleaved failed).damaged = true := by decide

/-- After: no serial order damages anything, from any state that was undamaged. -/
theorem locked_safe (w : W) (h : w.damaged = false) :
    (lockedBefore w).damaged = false ∧ (lockedAfter w).damaged = false := by
  cases w with
  | mk t l d =>
    simp only at h
    subst h
    cases t <;> cases l <;> decide

/-- And the retry's work always survives a locked cleanup that runs first. -/
theorem locked_retry_keeps_tail (w : W) : (lockedBefore w).liveTail = true := by
  cases w with
  | mk t l d => cases t <;> rfl

end LockedCleanup
end SyrusModel
