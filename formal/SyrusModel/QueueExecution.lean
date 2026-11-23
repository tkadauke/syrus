/-!
# SolidQueue execution states and the "orphaned job" classifier

An unfinished SolidQueue job carries at most one execution row. The reconciler
calls a queued Run's job *orphaned* — unreachable by every worker, so safe to
delete and re-enqueue — when it carries none.

The classifier enumerated four of the five execution kinds. `RunJob` is
concurrency-limited per Job, so a second Run of the same Job sits in
`blocked` until the semaphore frees. Old behavior: that waiting job was
"orphaned", deleted and re-enqueued (where it blocked again).

The Ruby classifier also waits a grace period after the job's last change
before calling it orphaned, so a job moving between states during the
snapshot scan is not misread. That age condition only ever withholds the
verdict; it is orthogonal to the flag classification modelled here.
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

/-! ## The snapshot reads each execution table separately

The reconciler loads ready, claimed, failed, scheduled and blocked executions in
separate queries. A job that moves between states during the scan (a delayed
job promoted from scheduled to ready, a claim landing between two reads) can
show no flag at all for one pass, though it always held an execution row. Such
a job was flagged and re-enqueued while in transit. The classifier now also
requires the job to have been unchanged past a grace period (`settled`): a job
in transit was just changed, so it is never flagged. -/

/-- What the snapshot shows for a job: a torn read can drop its one flag. -/
def observed (torn : Bool) (e : Exec) : Flags :=
  if torn then flags true .none else flags true e

def orphanedSettled (f : Flags) (settled : Bool) : Bool := orphanedAfter f && settled

/-- A torn read alone made the old classifier flag a job that had a row. -/
theorem torn_read_misclassifies : orphanedAfter (observed true .scheduled) = true := by decide

/-- **No job in transit is flagged.** A job that just changed is not settled,
    whatever the snapshot showed. -/
theorem transit_never_flagged (torn : Bool) (e : Exec) :
    orphanedSettled (observed torn e) false = false := by
  cases torn <;> cases e <;> decide

/-- **A real orphan is still found** once it has sat past the grace period. -/
theorem settled_orphan_flagged : orphanedSettled (observed false .none) true = true := by decide

end QueueExecution
end SyrusModel
