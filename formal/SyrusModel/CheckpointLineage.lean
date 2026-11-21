/-!
# DOC-44 Phase 3: checkpoint resume continues the attempt being retried

DOC-44: "Checkpoint resume uses the intended source revision and lineage."

Every retry (`RetryWorkflowEnqueuer`, operator and automatic) first tries
`RunCheckpointResume`, which restores a published checkpoint of a failed
attempt and re-runs from its failed Step. The attempt a retry continues is
the Job's newest one.

`source_workflow` scanned the Job's failed workflows and took the first with a
resumable checkpoint, so a newer attempt that could not be resumed (a later
failure elsewhere) or had succeeded (a feedback workflow that pushed) did not
stop it from restoring and pushing an older attempt's code
(`older_checkpoint_resumed`). Its "newest first" sort was also appended to
`job.workflows`' default ascending order (`AssociationOrder.lean`), so it
actually scanned oldest first.

After the fix only the Job's newest first-class workflow can be the source.

Model: attempts newest last; each says whether it failed and is resumable.
-/

namespace SyrusModel
namespace CheckpointLineage

structure Attempt where
  id : Nat
  failed : Bool
  resumable : Bool
  deriving DecidableEq, Repr

/-- Before: the first resumable failed attempt, scanning oldest first (the
    ordering bug). -/
def before (attempts : List Attempt) : Option Nat :=
  (attempts.find? (fun a => a.failed && a.resumable)).map (·.id)

/-- After: the newest attempt, only if it is a resumable failure. -/
def after (attempts : List Attempt) : Option Nat :=
  match attempts.getLast? with
  | some a => if a.failed && a.resumable then some a.id else none
  | none => none

theorem older_checkpoint_resumed :
    before [⟨1, true, true⟩, ⟨2, false, false⟩] = some 1 ∧ after [⟨1, true, true⟩, ⟨2, false, false⟩] = none := by decide

/-- After the fix, a resume only ever continues the newest attempt. -/
theorem after_newest (attempts : List Attempt) (id : Nat) (h : after attempts = some id) :
    (attempts.getLast?.map (·.id)) = some id := by
  unfold after at h
  cases hl : attempts.getLast? with
  | none => simp [hl] at h
  | some a =>
    rw [hl] at h
    by_cases hc : (a.failed && a.resumable) = true
    · simp only [hc, if_true, Option.some.injEq] at h; simp [h]
    · simp [hc] at h

end CheckpointLineage
end SyrusModel
