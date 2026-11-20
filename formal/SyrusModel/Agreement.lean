/-!
# Agreement between domain logic and the reconciler

The reconciler is a second controller acting on the same records as the
domain logic. If the reconciler "repairs" a state that the domain logic
deliberately produces, the two oscillate forever: each pass of one undoes the
other. Nothing ever looks stuck, so nobody notices, but every pass writes rows
and emits repair audit events.

`Agrees ctrl recon` says the reconciler never changes a state the domain
controller just decided on. Together with `Commutes` it gives convergence: after
one domain decision, no interleaving of the two controllers changes the state.
-/

namespace SyrusModel
namespace Agreement

/-- The reconciler leaves every state the domain controller produces alone. -/
def Agrees {α : Type} (ctrl recon : α → α) : Prop := ∀ w, recon (ctrl w) = ctrl w

/-- A reconciler repair never changes what the domain controller would decide. -/
def Commutes {α : Type} (ctrl recon : α → α) : Prop := ∀ w, ctrl (recon w) = ctrl w

/-- Any interleaving of the two controllers. -/
inductive Run {α : Type} (ctrl recon : α → α) : α → α → Prop
  | refl (x : α) : Run ctrl recon x x
  | ctrl {a b : α} : Run ctrl recon a b → Run ctrl recon a (ctrl b)
  | recon {a b : α} : Run ctrl recon a b → Run ctrl recon a (recon b)

/-- Convergence: once the domain controller has decided, the state is final under
    every interleaving, provided the domain decision is idempotent. -/
theorem converges {α : Type} {ctrl recon : α → α}
    (hidem : ∀ w, ctrl (ctrl w) = ctrl w) (hag : Agrees ctrl recon) (w : α) {v : α}
    (hr : Run ctrl recon (ctrl w) v) : v = ctrl w := by
  induction hr with
  | refl => rfl
  | ctrl _ ih => rw [ih, hidem]
  | recon _ ih => rw [ih, hag]

/-! ## Instance: dependency waits on intents with an active unit

`WorkIntents::JobWakeup` runs `WorkIntents::Scheduler.evaluate!` on a Job's
current intents. When a dependency is unsatisfied the gate fails and the intent
is parked `waiting` (reason `dependency`), *even though* the Job's queued
Workflow already has an active WorkUnit — `job_wakeup_spec.rb` asserts exactly
this, and the Job page shows the wait reason. When the gate passes again a
managed wait is cleared back to `requested`.

`classify_waiting_work_intents_with_active_units` flags every waiting intent with
an active unit and its repair calls `request!`. Production showed the same
handful of intents flipped on every periodic reconcile.
-/

inductive IState where
  | requested | waiting
  deriving DecidableEq, Repr

structure Intent where
  state : IState
  /-- Some WorkUnit of this intent is queued, blocked or running. -/
  activeUnit : Bool
  /-- The intent's gates pass (here: dependencies satisfied). External input. -/
  gatesPass : Bool
  deriving DecidableEq, Repr

/-- `Scheduler.evaluate!` (dependency is a managed wait reason). -/
def wake (i : Intent) : Intent :=
  if i.gatesPass then { i with state := .requested } else { i with state := .waiting }

/-- The reconciler before the fix: `waiting ∧ activeUnit → request!`. -/
def reconBefore (i : Intent) : Intent :=
  if i.state = .waiting ∧ i.activeUnit then { i with state := .requested } else i

/-- The reconciler after the fix: only a *stale* wait (gates pass) is cleared. -/
def reconAfter (i : Intent) : Intent :=
  if i.state = .waiting ∧ i.activeUnit ∧ i.gatesPass then { i with state := .requested } else i

theorem wake_idem (i : Intent) : wake (wake i) = wake i := by
  unfold wake; cases i.gatesPass <;> simp

/-- Before the fix the controllers oscillate: a blocked dependent Job's intent
    is flipped by the reconciler and flipped back by the next wakeup. -/
theorem before_oscillates :
    let i : Intent := { state := .waiting, activeUnit := true, gatesPass := false }
    reconBefore i ≠ i ∧ wake (reconBefore i) = i := by decide

theorem before_disagrees : ¬ Agrees wake reconBefore := by
  intro h
  have := h { state := .waiting, activeUnit := true, gatesPass := false }
  simp [wake, reconBefore] at this

theorem after_agrees : Agrees wake reconAfter := by
  intro i; unfold wake reconAfter; cases i.gatesPass <;> simp

theorem after_commutes : Commutes wake reconAfter := by
  intro i; unfold wake reconAfter; split <;> simp_all

/-- After the fix, any interleaving converges after one wakeup. -/
theorem after_converges (i : Intent) {v : Intent} (hr : Run wake reconAfter (wake i) v) :
    v = wake i :=
  converges wake_idem after_agrees i hr

/-- The fix still repairs the abnormal state: a stale wait is cleared. -/
theorem after_clears_stale (i : Intent) (hw : i.state = .waiting) (ha : i.activeUnit = true)
    (hg : i.gatesPass = true) : (reconAfter i).state = .requested := by
  simp [reconAfter, hw, ha, hg]

/-- ...and never discards a justified wait (the Job page keeps its reason). -/
theorem after_keeps_justified (i : Intent) (hg : i.gatesPass = false) : reconAfter i = i := by
  simp [reconAfter, hg]


/-! ## Classifier ⇒ executor agreement

A classifier that fires on states where every repair it can plan is refused
produces a skipped repair on every pass, forever. `Actionable detect guard`
says: whenever the classifier fires, the executor's guard holds.

Instance: `classify_retryable_failures` fired on a failed Run regardless of its
Workflow's state, but every repair it plans (`retry_failed_step`,
`rebuild_merge_train`, `resume_failed_step`, `retry_workflow`) refuses a queued
or running Workflow. Production: a merge train's grade loop had failed graders
and the reconciler planned a refused retry on every pass for 5.5 hours.
-/

def Actionable {α : Type} (detect guard : α → Prop) : Prop := ∀ w, detect w → guard w

inductive WfState where
  | queued | running | succeeded | failed | cancelled
  deriving DecidableEq, Repr

structure FailedRun where
  workflow : WfState
  retryable : Bool
  deriving DecidableEq, Repr

def detectRetryBefore (r : FailedRun) : Prop := r.retryable = true
def detectRetryAfter (r : FailedRun) : Prop :=
  r.retryable = true ∧ r.workflow ≠ .queued ∧ r.workflow ≠ .running

/-- Conjunction of what the four plannable repairs require of the Workflow:
    none accepts an active one. -/
def retryGuard (r : FailedRun) : Prop := r.workflow ≠ .queued ∧ r.workflow ≠ .running

theorem retry_before_not_actionable : ¬ Actionable detectRetryBefore retryGuard := by
  intro h
  have := h ⟨.running, true⟩ rfl
  exact this.2 rfl

theorem retry_after_actionable : Actionable detectRetryAfter retryGuard :=
  fun _ h => ⟨h.2.1, h.2.2⟩

/-- Nothing that the old classifier caught on a finished Workflow is lost. -/
theorem retry_after_complete_on_finished (r : FailedRun)
    (hf : r.workflow ≠ .queued ∧ r.workflow ≠ .running) :
    detectRetryBefore r ↔ detectRetryAfter r := by
  constructor
  · intro h; exact ⟨h, hf⟩
  · intro h; exact h.1

/-! ## Instance: queued Step held by a pause

`classify_queued_steps_without_runs` flagged a ready queued Step with no Run;
its repair (`resume_queued_step` → `DeferredPhaseResume`) refuses while the
WorkUnit is blocked on a pause (`manual_pause`, `provider_availability`).
Production: one operator-paused rebase, ~500 refused resumes in 9 hours. -/

structure HeldStep where
  ready : Bool
  paused : Bool
  deriving DecidableEq, Repr

def detectResumeBefore (s : HeldStep) : Prop := s.ready = true
def detectResumeAfter (s : HeldStep) : Prop := s.ready = true ∧ s.paused = false
def resumeGuard (s : HeldStep) : Prop := s.paused = false

theorem resume_before_not_actionable : ¬ Actionable detectResumeBefore resumeGuard := by
  intro h
  have := h ⟨true, true⟩ rfl
  exact Bool.noConfusion this

theorem resume_after_actionable : Actionable detectResumeAfter resumeGuard := fun _ h => h.2

end Agreement
end SyrusModel
