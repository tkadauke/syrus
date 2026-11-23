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

/-- The classifier with the grace, as the conformance fixture names it: the same
predicate as `orphanedSettled`. "Old" is the job row's age. -/
def orphaned (f : Flags) (old : Bool) : Bool := orphanedSettled f old

theorem orphaned_eq_settled (f : Flags) (old : Bool) : orphaned f old = orphanedSettled f old := rfl

theorem orphaned_sound (e : Exec) (old : Bool) :
    orphaned (flags true e) old = true → e = .none := by
  cases e <;> cases old <;> decide

theorem orphaned_needs_age (f : Flags) : orphaned f false = false := by
  simp [orphaned, orphanedSettled]

/-! ## Reading the tables while jobs move (main 600a716d44, F118)

The snapshot reads the five execution tables one query at a time. SolidQueue
moves a job forward between them atomically: scheduled or blocked to ready,
ready to claimed, claimed to failed. If a move lands between two reads, the job
is seen only if its old table was read before the move or its new table after
it.

`transit_never_flagged` above assumes a job in transit is not `settled`. The
code's `settled` is the job row's age (`created_at`/`updated_at` older than the
grace), and promotion moves execution rows without touching the job row. So a
job scheduled minutes ago is settled when the dispatcher promotes it, and the
grace alone does not keep it from being flagged (`promoted_old_job_flagged`).
The read order does. -/

inductive Table | ready | claimed | scheduled | blocked | failed
  deriving DecidableEq, Repr

def forwardMoves : List (Table × Table) :=
  [ (.scheduled, .ready), (.blocked, .ready), (.ready, .claimed), (.claimed, .failed) ]

/-- The job sits in `src` for the first `k` reads and in `dst` for the rest. -/
def seen (order : List Table) (src dst : Table) (k : Nat) : Bool :=
  (order.take k).contains src || (order.drop k).contains dst

def safeOrder (order : List Table) : Bool :=
  forwardMoves.all fun (src, dst) => (List.range (order.length + 1)).all (seen order src dst)

/-- The order main read the tables in. -/
def oldOrder : List Table := [ .ready, .claimed, .failed, .scheduled, .blocked ]

/-- The order they are read in now: the order a job flows through them. -/
def flowOrder : List Table := [ .scheduled, .blocked, .ready, .claimed, .failed ]

theorem old_order_misses_promotion : seen oldOrder .scheduled .ready 1 = false := by decide

/-- Under the old order, a torn read of a promoted job whose row is old is
flagged: the grace's assumption fails for exactly this job. -/
theorem promoted_old_job_flagged : orphanedSettled (observed true .ready) true = true := by decide

theorem old_order_unsafe : safeOrder oldOrder = false := by decide

theorem flow_order_sees_every_move : safeOrder flowOrder = true := by decide

/-- Both orders read every table, so a job that does not move is seen either way. -/
theorem flow_order_complete (t : Table) : flowOrder.contains t = true := by
  cases t <;> decide

end QueueExecution
end SyrusModel
