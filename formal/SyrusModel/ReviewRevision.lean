/-!
# A Review-workspace decision applies only to the revision the operator reviewed

Derived from recent main commits (the Review workspace plugin, "Harden Review
workspace freshness"). The workspace sends `expected_revision: job.revision`
with approve and feedback, and the app API rejects a mismatch
(`Api::V1::App::BaseController#reject_stale_job_revision?`).

The revision is `Job#entity_revision` (`Revisionable`): incremented on every
save of the Job row. Callback-skipping writes (`update_column(s)`) leave it
unchanged; the ones on Job touch only post-landing fields (`landed_sha`,
`branch_deleted_at`, ...), never the reviewable diff. Every change to the
diff happens inside a Workflow, whose state transitions save the Job.

Model: a history of events after the review. A `save` bumps the revision
and may change the diff; a `columnWrite` changes neither (the audited
assumption `columnWrite` never touches the diff is built into the type).
Proved: if the revision the operator saw is still current when the decision
arrives, the diff is exactly the one they reviewed
(`same_revision_same_diff`). No bug found.
-/

namespace SyrusModel
namespace ReviewRevision

inductive Event where
  /-- A Job save: revision + 1, the diff becomes `diff`. -/
  | save (diff : Nat)
  /-- `update_column(s)` on a non-diff field. -/
  | columnWrite
  deriving DecidableEq, Repr

structure JobState where
  revision : Nat
  diff : Nat
  deriving DecidableEq, Repr

def step (j : JobState) : Event → JobState
  | .save d => ⟨j.revision + 1, d⟩
  | .columnWrite => j

def run (j : JobState) (es : List Event) : JobState := es.foldl step j

theorem run_revision_ge (j : JobState) (es : List Event) : j.revision ≤ (run j es).revision := by
  induction es generalizing j with
  | nil => exact Nat.le_refl _
  | cons e es ih =>
    show j.revision ≤ (run (step j e) es).revision
    cases e with
    | save d => exact Nat.le_trans (Nat.le_succ _) (ih (step j (.save d)))
    | columnWrite => exact ih _

/-- Unchanged revision means no save happened, so the diff is unchanged. -/
theorem same_revision_same_diff (j : JobState) (es : List Event)
    (h : (run j es).revision = j.revision) : (run j es).diff = j.diff := by
  induction es generalizing j with
  | nil => rfl
  | cons e es ih =>
    cases e with
    | save d =>
      exfalso
      have := run_revision_ge (step j (.save d)) es
      simp only [run, List.foldl, step] at h this
      omega
    | columnWrite => exact ih j h

/-- The guard: a decision carrying the reviewed revision is accepted only if
    that revision is still current, and then it acts on the reviewed diff. -/
def accepted (reviewed : JobState) (current : JobState) : Bool := current.revision == reviewed.revision

theorem accepted_acts_on_reviewed_diff (j : JobState) (es : List Event)
    (h : accepted j (run j es) = true) : (run j es).diff = j.diff :=
  same_revision_same_diff j es (by simpa [accepted] using h)

end ReviewRevision
end SyrusModel
