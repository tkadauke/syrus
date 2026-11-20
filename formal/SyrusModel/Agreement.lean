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

/-! ## Instance: stack start blocks

The dispatcher sets `stack_dependencies_not_ready` from `JobStackResolver`; the
reconciler judged the block stale from `dependencies_satisfied_for_execution?`
alone. Stack readiness implies dependency satisfaction but not conversely, so
with dependencies satisfied and the stack not ready the reconciler planned
`start_workflow` and the dispatcher refused it (~200 times in 9 hours). -/

structure StackState where
  depsSatisfied : Bool
  stackReady : Bool
  deriving DecidableEq, Repr

/-- Readiness as the dispatcher decides it. -/
def dispatcherStarts (s : StackState) : Prop := s.depsSatisfied = true ∧ s.stackReady = true

def staleBefore (s : StackState) : Prop := s.depsSatisfied = true
def staleAfter (s : StackState) : Prop := s.depsSatisfied = true ∧ s.stackReady = true

theorem stack_before_not_actionable : ¬ Actionable staleBefore dispatcherStarts := by
  intro h
  have := (h ⟨true, false⟩ rfl).2
  exact Bool.noConfusion this

theorem stack_after_actionable : Actionable staleAfter dispatcherStarts := fun _ h => h

/-! ## Instance: a Step waiting for an in-place retry

When a failed Run qualifies for an in-place step retry
(`AutoRetryAttempt::IN_PLACE_STEP_CLASSIFICATIONS`: `worker_died`,
`git_transport_transient`), `Runs::LifecyclePropagation` schedules the retry and
deliberately leaves the Step running. `classify_active_steps_with_terminal_runs`
exempted only `worker_died`, so a `git_transport_transient` retry (5 minute
backoff) was thrown away by the next pass, which failed the Step from its
failed Run. Production: one merge train lost 12 grader retries this way in a
minute. -/

inductive Cls where
  | workerDied | gitTransient | other
  deriving DecidableEq, Repr

def inPlace : Cls → Bool
  | .workerDied | .gitTransient => true
  | .other => false

structure WaitingStep where
  /-- Step is running and every Run is terminal. -/
  allRunsTerminal : Bool
  /-- A pending in-place retry of this class exists, if any. -/
  pendingRetry : Option Cls
  deriving DecidableEq, Repr

/-- What the domain intends: the Step is still owned by a scheduled retry. -/
def awaitingRetry (s : WaitingStep) : Bool :=
  match s.pendingRetry with
  | some c => inPlace c
  | none => false

def detectTerminalBefore (s : WaitingStep) : Prop :=
  s.allRunsTerminal = true ∧ s.pendingRetry ≠ some .workerDied
def detectTerminalAfter (s : WaitingStep) : Prop :=
  s.allRunsTerminal = true ∧ awaitingRetry s = false

/-- The reconciler may only finish a Step the domain is not waiting on. -/
def respectsRetry (s : WaitingStep) : Prop := awaitingRetry s = false

theorem terminal_before_not_actionable : ¬ Actionable detectTerminalBefore respectsRetry := by
  intro h
  have := h ⟨true, some .gitTransient⟩ ⟨rfl, by decide⟩
  exact Bool.noConfusion this

theorem terminal_after_actionable : Actionable detectTerminalAfter respectsRetry := fun _ h => h.2

/-- Nothing else is lost: with no pending in-place retry both classifiers agree. -/
theorem terminal_after_complete (s : WaitingStep) (h : s.pendingRetry = none) :
    detectTerminalBefore s ↔ detectTerminalAfter s := by
  simp [detectTerminalBefore, detectTerminalAfter, awaitingRetry, h]

/-! ## Instance: lifting a Job to running

`Workflows::JobLifecyclePropagation#start!` leaves the Job alone for a
lifecycle-owning Workflow (`coworker_run`, `main_branch_repair`, landing) and
for an implemented Job under a non-approval-blocking follow-up; `Steps::PrOpen`
marks the Job implemented while the rest of the chain runs. The reconciler's
`[queued|implemented, running]` repair lifted every one of them to running.
Production: 75 + 41 repairs in ~2.5 days. -/

inductive JState where
  | queued | implemented | running
  deriving DecidableEq, Repr

structure StartCtx where
  job : JState
  ownsLifecycle : Bool
  nonBlocking : Bool
  publishedInWorkflow : Bool
  deriving DecidableEq, Repr

/-- The domain's rule (`lifts_job_on_start?`). -/
def lifts (c : StartCtx) : Bool :=
  !c.ownsLifecycle && !(c.job = .implemented && c.nonBlocking)

/-- Job state the domain leaves behind once the Workflow is running. -/
def domainState (c : StartCtx) : JState :=
  if c.job = .implemented && c.publishedInWorkflow then .implemented
  else if lifts c then .running else c.job

def liftBefore (c : StartCtx) : Bool := c.job ≠ .running
def liftAfter (c : StartCtx) : Bool :=
  c.job ≠ .running && lifts c && !(c.job = .implemented && c.publishedInWorkflow)

/-- The reconciler may only lift a Job the domain would have lifted. -/
def liftAgrees (detect : StartCtx → Bool) : Prop :=
  ∀ c, detect c = true → domainState c = .running

theorem lift_before_disagrees : ¬ liftAgrees liftBefore := by
  intro h
  have := h ⟨.queued, true, false, false⟩ rfl
  exact absurd this (by decide)

/-- Exhaustive over all 24 contexts. -/
theorem lift_after_agrees : liftAgrees liftAfter := by
  intro ⟨j, o, n, p⟩
  cases j <;> cases o <;> cases n <;> cases p <;> decide

/-- The fix keeps every lift the domain would have made. -/
theorem lift_after_complete :
    ∀ c : StartCtx, c.job ≠ .running → domainState c = .running → liftAfter c = true := by
  intro ⟨j, o, n, p⟩
  cases j <;> cases o <;> cases n <;> cases p <;> decide

end Agreement
end SyrusModel
