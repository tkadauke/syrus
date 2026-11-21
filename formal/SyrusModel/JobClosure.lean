/-!
# Closing Jobs: no Workflow keeps running for a closed Job

Production showed Workflows starting Runs *after* their Job closed: a rebase
created for an Epic member seconds before the PR poller closed it as merged,
then started a second later with a `force_push` queued. Close paths cancelled
only active Runs, so queued or between-steps Workflows survived until the
reconciler's `closed_job_active_runtime_work` repair cancelled them.

Operator decision: a Workflow that closes its own Job may only do so as its
final act. Model that as a *pending closure* recorded on the Workflow and
applied when the Workflow finishes, whatever its outcome.

Invariant `ClosedQuiet`: no active Workflow has a closed Job among its members
(its own Job, or a merge train's member Jobs).

The model shows the closing primitive must also cancel the Job's *other*
active Workflows (`closeNow`): deferring to a landing and later closing
"plainly" would leave, say, a concurrent rebase running on a closed Job
(`plainClose_breaks`).
-/

namespace SyrusModel
namespace JobClosure

structure Wf (nJ : Nat) where
  active : Bool
  landing : Bool
  /-- Jobs this Workflow works on (WorkUnit members). -/
  member : Fin nJ → Bool
  /-- Jobs to close when this Workflow finishes. -/
  pending : Fin nJ → Bool

structure World (nJ nW : Nat) where
  closed : Fin nJ → Bool
  wf : Fin nW → Wf nJ

variable {nJ nW : Nat}

def upd {α : Type} {n : Nat} (f : Fin n → α) (i : Fin n) (v : α) : Fin n → α :=
  fun j => if j = i then v else f j

namespace World
variable (s : World nJ nW)

def ClosedQuiet : Prop := ∀ w j, (s.wf w).active = true → (s.wf w).member j = true → s.closed j = false

instance : Decidable s.ClosedQuiet := by unfold ClosedQuiet; infer_instance

/-- Close `j` now: cancel every active Workflow working on it, then close. -/
def closeNow (j : Fin nJ) : World nJ nW :=
  { closed := upd s.closed j true
    wf := fun w => if (s.wf w).member j then { s.wf w with active := false } else s.wf w }

/-- The old behavior: close without touching Workflows. -/
def plainClose (j : Fin nJ) : World nJ nW := { s with closed := upd s.closed j true }

/-- Some active landing Workflow is working on `j`. -/
def landingOwner (j : Fin nJ) (w : Fin nW) : Prop :=
  (s.wf w).active = true ∧ (s.wf w).landing = true ∧ (s.wf w).member j = true

instance (j : Fin nJ) (w : Fin nW) : Decidable (s.landingOwner j w) := by
  unfold landingOwner; infer_instance

/-- A step of active Workflow `w` asks for `j` to be closed when `w` finishes. -/
def requestClose (w : Fin nW) (j : Fin nJ) : World nJ nW :=
  { s with wf := upd s.wf w { s.wf w with pending := upd (s.wf w).pending j true } }

/-- External close (PR poller, grace expiry, …): when an active landing
    Workflow `w` owns the Job, defer to it (`requestClose w j`); otherwise
    `closeNow j`. Both cases are covered by the theorems below. -/
def externalClose (j : Fin nJ) (owner : Option (Fin nW)) : World nJ nW :=
  match owner with
  | some w => s.requestClose w j
  | none => s.closeNow j

/-- Apply pending closures one Job at a time, each with `closeNow`. -/
def applyPending (w : Fin nW) : List (Fin nJ) → World nJ nW → World nJ nW
  | [], t => t
  | j :: js, t => applyPending w js (if (s.wf w).pending j then t.closeNow j else t)

/-- `w` finishes (any terminal state), then its pending closures are applied. -/
def finish (w : Fin nW) : World nJ nW :=
  let t : World nJ nW := { s with wf := upd s.wf w { s.wf w with active := false } }
  s.applyPending w (List.finRange nJ) t

end World

open World

theorem closeNow_quiet {s : World nJ nW} (j : Fin nJ) (h : s.ClosedQuiet) : (s.closeNow j).ClosedQuiet := by
  intro w k ha hm
  simp only [closeNow] at ha hm ⊢
  by_cases hmj : (s.wf w).member j = true
  · simp [hmj] at ha
  · simp only [hmj, Bool.false_eq_true, ite_false] at ha hm
    simp only [upd]
    by_cases hk : k = j
    · subst hk; exact absurd hm hmj
    · simp [hk]; exact h w k ha hm

theorem requestClose_quiet {s : World nJ nW} (w : Fin nW) (j : Fin nJ) (h : s.ClosedQuiet) :
    (s.requestClose w j).ClosedQuiet := by
  intro v k ha hm
  simp only [requestClose, upd] at ha hm ⊢
  by_cases hv : v = w
  · subst hv; simp at ha hm; exact h v k ha hm
  · simp [hv] at ha hm; exact h v k ha hm

theorem externalClose_quiet {s : World nJ nW} (j : Fin nJ) (owner : Option (Fin nW))
    (h : s.ClosedQuiet) : (s.externalClose j owner).ClosedQuiet := by
  cases owner with
  | some w => exact requestClose_quiet w j h
  | none => exact closeNow_quiet j h

theorem applyPending_quiet {s : World nJ nW} (w : Fin nW) :
    ∀ (js : List (Fin nJ)) (t : World nJ nW), t.ClosedQuiet → (s.applyPending w js t).ClosedQuiet
  | [], _, ht => ht
  | j :: js, t, ht => by
    simp only [applyPending]
    apply applyPending_quiet w js
    split
    · exact closeNow_quiet j ht
    · exact ht

theorem finish_quiet {s : World nJ nW} (w : Fin nW) (h : s.ClosedQuiet) : (s.finish w).ClosedQuiet := by
  unfold finish
  apply applyPending_quiet
  intro v k ha hm
  simp only [upd] at ha hm
  by_cases hv : v = w
  · simp [hv] at ha
  · simp [hv] at ha hm; exact h v k ha hm

/-- Every pending closure is honored once the Workflow finishes. -/
theorem applyPending_closes {s : World nJ nW} (w : Fin nW) :
    ∀ (js : List (Fin nJ)) (t : World nJ nW) (j : Fin nJ),
      (j ∈ js ∧ (s.wf w).pending j = true) ∨ t.closed j = true →
      (s.applyPending w js t).closed j = true
  | [], _, _, h => by
    rcases h with ⟨hm, _⟩ | h
    · cases hm
    · exact h
  | k :: js, t, j, h => by
    simp only [applyPending]
    apply applyPending_closes w js
    by_cases hkj : k = j
    · subst hkj
      rcases h with ⟨_, hp⟩ | hc
      · right; simp [hp, closeNow, upd]
      · right
        split
        · simp [closeNow, upd]
        · exact hc
    · rcases h with ⟨hm, hp⟩ | hc
      · left
        refine ⟨?_, hp⟩
        rcases List.mem_cons.mp hm with he | hm'
        · exact absurd he.symm hkj
        · exact hm'
      · right
        split
        · simp only [closeNow, upd]; simp [hc]
        · exact hc

theorem finish_honors_pending {s : World nJ nW} (w : Fin nW) (j : Fin nJ)
    (hp : (s.wf w).pending j = true) : (s.finish w).closed j = true :=
  applyPending_closes w _ _ j (Or.inl ⟨List.mem_finRange j, hp⟩)

/-- The old close leaves a concurrent Workflow running on the closed Job. -/
theorem plainClose_breaks :
    let s : World 1 1 := { closed := fun _ => false,
                           wf := fun _ => ⟨true, false, fun _ => true, fun _ => false⟩ }
    s.ClosedQuiet ∧ ¬ (s.plainClose 0).ClosedQuiet := by
  decide

end JobClosure
end SyrusModel
