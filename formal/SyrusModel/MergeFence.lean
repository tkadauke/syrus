/-!
# No merge after the landing was stopped

A landing step (`auto_merge`, `merge_train_land`, `external_pr_merge`) evaluates
its gate, then does several seconds of work (mergeability settling, approval
mirroring, validation parity), then calls GitHub's merge API — an effect that
cannot be undone. Meanwhile an operator's Stop Landing, or a Job closure,
cancels the Run and Workflow in the database. The step never looked again
before merging.

Fix: re-read the Run, Step and Workflow (`ensure_run_still_active!`)
immediately before the merge call. The remaining window is the single API
request itself.

A step is a sequence of local actions; the environment may cancel between any
two of them.
-/

namespace SyrusModel
namespace MergeFence

inductive Act where
  | gate      -- evaluate AutoMergeGate (reads run state implicitly via the workflow)
  | work      -- settle / mirror / parity: no state checks
  | recheck   -- ensure_run_still_active!
  | merge     -- the irreversible GitHub call
  deriving DecidableEq, Repr

structure S where
  runActive : Bool
  stopped : Bool    -- the step has stopped itself
  merged : Bool
  /-- The run was active at the instant of the merge. -/
  mergedWhileActive : Bool
  deriving DecidableEq, Repr

def act (s : S) : Act → S
  | .gate => if s.runActive then s else { s with stopped := true }
  | .work => s
  | .recheck => if s.runActive then s else { s with stopped := true }
  | .merge => if s.stopped then s else { s with merged := true, mergedWhileActive := s.runActive }

/-- Run the step; `cancelAt k` cancels the Run just before action `k`. -/
def run (acts : List Act) (cancelAt : Nat) : S :=
  (acts.zipIdx).foldl (fun s (a, i) =>
    let s := if i = cancelAt then { s with runActive := false } else s
    act s a) ⟨true, false, false, false⟩

def before : List Act := [.gate, .work, .work, .merge]
def after : List Act := [.gate, .work, .work, .recheck, .merge]

/-- Old: a cancel during the post-gate work still merges. -/
theorem before_merges_after_cancel :
    let s := run before 2
    s.merged = true ∧ s.mergedWhileActive = false := by decide

/-- Fixed: a merge only happens while the Run is active, unless the cancel lands
    in the one remaining gap — between the re-check and the merge request
    itself (index 4). Before the fix the unsafe window was every gap after the
    gate. -/
theorem after_merge_only_while_active :
    (List.range (after.length + 2)).all (fun k =>
      k = 4 || (let s := run after k; !s.merged || s.mergedWhileActive)) = true := by
  decide

theorem before_window_is_wider :
    ((List.range (before.length + 2)).filter fun k => let s := run before k; s.merged && !s.mergedWhileActive)
      = [1, 2, 3] := by
  decide

end MergeFence
end SyrusModel
