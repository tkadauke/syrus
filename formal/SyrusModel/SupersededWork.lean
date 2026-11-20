/-!
# The reconciler never cancels a Workflow for one that is waiting on it

`classify_superseded_active_runtime_work` flags a Job with two active
WorkUnit-owned Workflows and cancels every one but the newest. But ChatFeedback,
Rebase and StackRebase *materialize behind the Job lock*
(`materialize_behind_active_lock?`): the newer Workflow is queued, waiting for
the running one to finish. Taking it as the keeper cancelled the running
Workflow it was waiting for.

Workflows on one Job, oldest first; `waiting` = queued and of a kind that
materializes behind the lock.
-/

namespace SyrusModel
namespace SupersededWork

structure W where
  running : Bool
  waiting : Bool
  deriving DecidableEq, Repr

/-- Workflows the classifier would cancel: all but the last of the considered ones. -/
def cancelled (considered : List W) : List W := considered.dropLast

def before (ws : List W) : List W := cancelled ws
def after (ws : List W) : List W := cancelled (ws.filter fun w => !w.waiting)

def scenario : List W := [⟨true, false⟩, ⟨false, true⟩]

/-- Old: the running Workflow is cancelled in favour of the waiting one. -/
theorem before_cancels_running : (before scenario).any (·.running) = true := by decide

/-- Fixed: a waiting Workflow never causes a cancel, for every Job with up to
    four Workflows in any mix. -/
def allW : List W := [⟨true, false⟩, ⟨false, false⟩, ⟨false, true⟩]

def lists : Nat → List (List W)
  | 0 => [[]]
  | n + 1 => [[]] ++ (lists n).flatMap fun l => allW.map (· :: l)

theorem after_waiters_never_supersede :
    (lists 4).all (fun ws =>
      (after ws).length = ((ws.filter fun w => !w.waiting).length - 1) &&
      (after (ws ++ [⟨false, true⟩])) = after ws) = true := by
  decide

end SupersededWork
end SyrusModel
