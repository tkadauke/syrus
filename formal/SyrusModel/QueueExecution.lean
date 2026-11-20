/-!
# SolidQueue execution states and the "orphaned job" classifier

An unfinished SolidQueue job carries at most one execution row. The reconciler
calls a queued Run's job *orphaned* — unreachable by every worker, so safe to
delete and re-enqueue — when it carries none.

The classifier enumerated four of the five execution kinds. `RunJob` is
concurrency-limited per Job, so a second Run of the same Job sits in
`blocked` until the semaphore frees. Old behavior: that waiting job was
"orphaned", deleted and re-enqueued (where it blocked again).
-/

namespace SyrusModel
namespace QueueExecution

/-- The execution row an unfinished SolidQueue job carries, if any. -/
inductive Exec where
  | ready | claimed | scheduled | blocked | failed
  /-- no execution row: no dispatcher or worker will ever pick it up -/
  | none
  deriving DecidableEq, Repr

structure Flags where
  ready : Bool
  claimed : Bool
  scheduled : Bool
  blocked : Bool
  failed : Bool
  deriving DecidableEq, Repr

/-- The snapshot flags a job produces. `observeBlocked = false` is the old
    snapshot, which never loaded blocked executions. -/
def flags (observeBlocked : Bool) : Exec → Flags
  | .ready => ⟨true, false, false, false, false⟩
  | .claimed => ⟨false, true, false, false, false⟩
  | .scheduled => ⟨false, false, true, false, false⟩
  | .blocked => ⟨false, false, false, observeBlocked, false⟩
  | .failed => ⟨false, false, false, false, true⟩
  | .none => ⟨false, false, false, false, false⟩

def orphanedBefore (f : Flags) : Bool := !f.ready && !f.claimed && !f.scheduled && !f.failed
def orphanedAfter (f : Flags) : Bool := !f.ready && !f.claimed && !f.scheduled && !f.blocked && !f.failed

/-- Old classifier on the old snapshot: a blocked job reads as orphaned. -/
theorem before_misclassifies_blocked : orphanedBefore (flags false .blocked) = true := by decide

/-- **Soundness and completeness.** The fixed classifier flags a job exactly
    when it has no execution row. -/
theorem after_exact (e : Exec) : orphanedAfter (flags true e) = true ↔ e = .none := by
  cases e <;> decide

/-- Adding the flag alone is not enough: the old predicate ignores it. -/
theorem flag_alone_insufficient : orphanedBefore (flags true .blocked) = true := by decide

end QueueExecution
end SyrusModel
