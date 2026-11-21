/-!
# A live worker is never declared dead: whose queue claim executes a Run

Derived from a recent main commit ("Do not declare a worker dead over one
orphaned helper process"). Its invariant: a Run whose worker still holds a
live queue claim, and has not gone heartbeat-stale, is never failed as
`worker_died` (`WorkEngine::Reconciler#classify_running_runs`).

The guard reads `solid_queue_execution_live?(run)`, which counted only a
queue job whose root Run is the Run itself. But `RunJob` drives a sequential
Workflow depth-first: after a Step succeeds, the next Step's Run executes
inside the *same* RunJob, so every Run after the first in an inline chain has
no queue job of its own. Its worker's claim is the root Run's, and that root
Run has already finished. For those Runs the guard never fired, so one
orphaned helper process still failed a healthy chained Run, and with no queue
job of its own the Run also read as "detached" after a three-minute heartbeat
gap (`chained_run_unprotected`).

The fix attributes a workflow-mate's live claim to a Run when the mate's root
Run has finished. It still never attributes a *running* sibling's claim
(an existing rule: a parallel or still-running sibling executes itself), and a
distributed parallel Run only ever runs in its own job.

Model: a claim is held by the job of some root Run; `executing r` is the Run
that job is currently executing.
-/

namespace SyrusModel
namespace WorkerEvidence

inductive RunState where | running | finished deriving DecidableEq, Repr

structure Claim where
  root : Nat
  live : Bool
  /-- The Run this job is executing right now (its root, or an inline successor). -/
  executing : Nat
  deriving DecidableEq, Repr

structure World where
  claims : List Claim
  state : Nat → RunState
  /-- Runs of the same Workflow. -/
  mate : Nat → Nat → Bool
  distributed : Nat → Bool

/-- A real RunJob executes its root until it finishes, then inline successors
    of the same Workflow, never a distributed parallel Run that is not its root. -/
def World.Wellformed (w : World) : Prop :=
  ∀ c ∈ w.claims, c.executing = c.root ∨
    (w.state c.root = .finished ∧ w.mate c.root c.executing = true ∧ w.distributed c.executing = false)

/-- The truth: a live claim is executing the Run. -/
def executedLive (w : World) (r : Nat) : Prop := ∃ c ∈ w.claims, c.live = true ∧ c.executing = r

def ownClaim (w : World) (r : Nat) : Bool := w.claims.any (fun c => c.live && c.root == r)

def before (w : World) (r : Nat) : Bool := ownClaim w r

def after (w : World) (r : Nat) : Bool :=
  ownClaim w r ||
    (!w.distributed r && w.claims.any (fun c => c.live && w.mate c.root r && w.state c.root == .finished))

/-- The counterexample: Run 2 runs inline in Run 1's job, Run 1 has
    finished. The worker is alive, but the old guard does not see it. -/
def chained : World where
  claims := [⟨1, true, 2⟩]
  state := fun r => if r = 1 then .finished else .running
  mate := fun _ _ => true
  distributed := fun _ => false

theorem chained_run_unprotected : executedLive chained 2 ∧ before chained 2 = false :=
  ⟨⟨⟨1, true, 2⟩, by simp [chained], rfl, rfl⟩, by decide⟩

/-- After the fix, any Run a live claim is executing is recognised as live:
    neither an orphaned helper nor a missing queue job of its own can get it
    failed as worker-died while that claim holds. -/
theorem after_complete (w : World) (hw : w.Wellformed) (r : Nat) (h : executedLive w r) : after w r = true := by
  obtain ⟨c, hc, hl, he⟩ := h
  rcases hw c hc with hroot | ⟨hfin, hmate, hdist⟩
  · have : ownClaim w r = true := List.any_eq_true.mpr ⟨c, hc, by simp [hl, ← he, hroot]⟩
    simp [after, this]
  · subst he
    have : w.claims.any (fun c' => c'.live && w.mate c'.root c.executing && w.state c'.root == .finished) = true :=
      List.any_eq_true.mpr ⟨c, hc, by simp [hl, hmate, hfin]⟩
    simp [after, hdist, this]

/-- And it never borrows a running sibling's claim: a claim whose root is
    still running counts only for that root. -/
theorem after_ignores_running_siblings (w : World) (r : Nat)
    (h : ∀ c ∈ w.claims, c.live = true → c.root ≠ r → w.state c.root = .running) :
    after w r = before w r := by
  unfold after before
  cases ho : ownClaim w r with
  | true => simp
  | false =>
    have : w.claims.any (fun c => c.live && w.mate c.root r && w.state c.root == .finished) = false := by
      rw [List.any_eq_false]
      intro c hc hx
      simp only [Bool.and_eq_true, beq_iff_eq] at hx
      obtain ⟨⟨hl, _⟩, hf⟩ := hx
      by_cases hr : c.root = r
      · -- its own claim, which `ownClaim` already counts
        have : ownClaim w r = true := List.any_eq_true.mpr ⟨c, hc, by simp [hl, hr]⟩
        rw [ho] at this; exact Bool.noConfusion this
      · rw [h c hc hl hr] at hf; exact RunState.noConfusion hf
    simp [this]

end WorkerEvidence
end SyrusModel
