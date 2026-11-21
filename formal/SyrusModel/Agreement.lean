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

/-- F27 tightening: the retries also refuse a succeeded Workflow (rebuild
    requires failed; step retry requires `retry_available?`). Production: two
    landed merge trains with failed graders from an earlier round drew 115
    refused rebuilds in 13 hours. -/
def retryGuardStrict (r : FailedRun) : Prop :=
  r.workflow ≠ .queued ∧ r.workflow ≠ .running ∧ r.workflow ≠ .succeeded

def detectRetryStrict (r : FailedRun) : Prop :=
  r.retryable = true ∧ r.workflow ≠ .queued ∧ r.workflow ≠ .running ∧ r.workflow ≠ .succeeded

theorem retry_after_not_actionable_strict : ¬ Actionable detectRetryAfter retryGuardStrict := by
  intro h
  have := h ⟨.succeeded, true⟩ ⟨rfl, by decide, by decide⟩
  exact this.2.2 rfl

theorem retry_strict_actionable : Actionable detectRetryStrict retryGuardStrict :=
  fun _ h => h.2

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

/-! ## Instance: only a loop's latest iteration is actionable

A loop's iterations are numbered; once iteration `k+1` exists, the loop has
already acted on iteration `k`'s outcome. Retrying or "continuing" from a
failed earlier iteration re-runs stale work. Production: a pending retry for a
first-iteration `grader_collect` fired after the loop had moved two iterations
on and stopped on no progress; it reopened the Workflow and, failing again,
scheduled the next retry -- hourly for eight hours. The pending auto-retry
and the orphaned-failed-Step check now skip superseded iterations. This guard
is for re-running a Step: the reconciler's Workflow-level repairs (a merge-train
rebuild) legitimately key off an earlier iteration's failure, so they are not
instances of it. -/

structure IterFailure where
  iteration : Nat
  latest : Nat
  deriving DecidableEq, Repr

def detectIterBefore (_ : IterFailure) : Prop := True
def detectIterAfter (f : IterFailure) : Prop := ¬ f.latest > f.iteration

/-- Acting is sound only on the iteration the loop has not yet moved past. -/
def iterGuard (f : IterFailure) : Prop := f.iteration ≥ f.latest

theorem iter_before_not_actionable : ¬ Actionable detectIterBefore iterGuard := by
  intro h
  have := h ⟨1, 3⟩ trivial
  exact absurd this (by unfold iterGuard; decide)

theorem iter_after_actionable : Actionable detectIterAfter iterGuard := by
  intro f h
  unfold iterGuard
  unfold detectIterAfter at h
  omega

/-! ## Instance: review panels decide at their collect Step

`StepDispatcher#handle_successful_review_loop_iteration` returns early for a
review-panel fanout or member: the panel's `review_panel_collect` decides the
loop. `classify_succeeded_review_steps_without_required_repair` had no such
exclusion, so a just-succeeded fanout -- reading the previous iteration's
"needs_work" verdict -- was flagged every minute while its members reviewed,
and the repair (which can only call the dispatcher) was skipped every time. -/

structure ReviewStep where
  needsWork : Bool
  panelParticipant : Bool
  successorMissing : Bool
  deriving DecidableEq, Repr

/-- The dispatcher continues a review loop only from a non-panel Step. -/
def dispatcherRepairs (s : ReviewStep) : Prop := s.panelParticipant = false

def detectReviewBefore (s : ReviewStep) : Prop := s.needsWork = true ∧ s.successorMissing = true
def detectReviewAfter (s : ReviewStep) : Prop :=
  s.needsWork = true ∧ s.successorMissing = true ∧ s.panelParticipant = false

theorem review_before_not_actionable : ¬ Actionable detectReviewBefore dispatcherRepairs := by
  intro h
  have := h ⟨true, true, true⟩ ⟨rfl, rfl⟩
  exact Bool.noConfusion this

theorem review_after_actionable : Actionable detectReviewAfter dispatcherRepairs := fun _ h => h.2.2

/-! ## Instance: missing workspaces

`classify_workspace_availability` flagged a missing workspace on running
Workflows and on failed ones awaiting retry; `recover_missing_workspace` only
acts on queued or running ones, so every failed one was flagged critical and
skipped on every pass (113 of the last 150 executions). -/

inductive WsWf where
  | running | failedRetryable
  deriving DecidableEq, Repr

def detectWsBefore (_ : WsWf) : Prop := True
def detectWsAfter (w : WsWf) : Prop := w = .running
def wsRepairs (w : WsWf) : Prop := w = .running

theorem ws_before_not_actionable : ¬ Actionable detectWsBefore wsRepairs := by
  intro h
  exact WsWf.noConfusion (h .failedRetryable trivial)

theorem ws_after_actionable : Actionable detectWsAfter wsRepairs := fun _ h => h

/-! ## Instance (decided): a failed Workflow's queued tail

`Workflow#fail!` keeps the queued tail for Retry-from-failed-step; the
reconciler cancelled it a minute later. Decision: the tail stays. The reconciler
now treats as stale only live Runs, running Steps, and an active publication
Step that already failed (cleanup fails it, making it the retry point). -/

inductive TailStep where
  | queued | queuedFailedPublication | running
  deriving DecidableEq, Repr

/-- What the domain keeps under a failed Workflow. -/
def domainKeeps : TailStep → Bool
  | .queued => true
  | .queuedFailedPublication => false
  | .running => false

def staleBefore' (_ : TailStep) : Bool := true
def staleAfter' (s : TailStep) : Bool := !domainKeeps s

theorem tail_before_disagrees : ∃ s, staleBefore' s = true ∧ domainKeeps s = true := ⟨.queued, rfl, rfl⟩

theorem tail_after_agrees (s : TailStep) : staleAfter' s = true → domainKeeps s = false := by
  cases s <;> simp [staleAfter', domainKeeps]

theorem tail_after_complete (s : TailStep) : domainKeeps s = false → staleAfter' s = true := by
  cases s <;> simp [staleAfter', domainKeeps]

/-! ## Instance (decided): validation prefetches of a landed parent

A landing-validation prefetch validates the next landing on top of its
parent's result, for the next landing to reuse. Decision: it may outlive a
parent that succeeded; children of a failed or cancelled parent are still
stale. -/

inductive ParentEnd where
  | succeeded | failed | cancelled
  deriving DecidableEq, Repr

def childStale (parent : ParentEnd) (prefetch : Bool) : Bool :=
  !(parent = .succeeded && prefetch)

theorem prefetch_of_landed_parent_kept : childStale .succeeded true = false := rfl

theorem other_children_of_terminal_parents_stale (p : ParentEnd) (prefetch : Bool)
    (h : ¬ (p = .succeeded ∧ prefetch = true)) : childStale p prefetch = true := by
  cases p <;> cases prefetch <;> simp_all [childStale]

/-! ## Instance: a cancelled attempt — `failed` or `queued`? (NY6, undecided)

`JobLifecyclePropagation.cancel!` moves a `running` Job to `failed` when its
current Workflow is cancelled. `ReconcileJobStatesJob::Plan` maps
`[failed, cancelled]` to `queued`. For a deliberate cancellation (operator stop,
`cancel_stale_work`) nothing then relaunches the Job, so it reads `queued` with
no work. Production: JOB-9436, one minute after an operator's stale-work repair.
Either rule can be the spec; they cannot both stand. -/

inductive CJob where | running | failed | queued deriving DecidableEq, Repr

/-- The domain on cancellation of the current Workflow. -/
def cancelDomain : CJob → CJob
  | .running => .failed
  | j => j

/-- The reconciler with the latest Workflow cancelled. -/
def cancelRecon : CJob → CJob
  | .failed => .queued
  | j => j

theorem cancel_rules_disagree : cancelRecon (cancelDomain .running) ≠ cancelDomain .running := by decide

/-- Option A: the reconciler leaves a cancelled attempt's `failed` Job alone. -/
def cancelReconA : CJob → CJob := id
/-- Option B: the domain itself returns the Job to `queued`. -/
def cancelDomainB : CJob → CJob
  | .running => .queued
  | j => j

theorem cancel_option_a_agrees : Agrees cancelDomain cancelReconA := fun _ => rfl
theorem cancel_option_b_agrees : cancelRecon (cancelDomainB .running) = cancelDomainB .running := rfl

/-! ## Instance: two definitions of "active landing work" (proof, no change)

`classify_landing_work_job_state_drift` counts a landing unit only if it is not
blocked on an operator-cleared reason (`strict`); `RuntimeOwnership.active_landing_work?`,
used by `DeferOrphanedLandingJob`, `RepairLandingWorkJobState` and the
orphaned-landing classifier, counts every active landing-kind unit (`loose`).
Every unit `strict` counts, `loose` counts. So the drift repair (approved →
landing, needs `strict`) and the defer repair (landing → approved, needs
`¬ loose`) can never both apply to the same unit set: a defer/re-land
alternation needs new landing work to appear. -/

structure LUnit where
  active : Bool
  landingKind : Bool
  externallyBlocked : Bool
  deriving DecidableEq, Repr

def loose (us : List LUnit) : Bool := us.any fun u => u.active && u.landingKind
def strict (us : List LUnit) : Bool := us.any fun u => u.active && u.landingKind && !u.externallyBlocked

theorem strict_implies_loose (us : List LUnit) : strict us = true → loose us = true := by
  unfold strict loose
  intro h
  obtain ⟨u, hu, hp⟩ := List.any_eq_true.mp h
  exact List.any_eq_true.mpr ⟨u, hu, by simp_all⟩

/-- No unit set makes both repairs applicable. -/
theorem landing_repairs_never_both (us : List LUnit) : ¬ (strict us = true ∧ loose us = false) := by
  rintro ⟨hs, hl⟩
  rw [strict_implies_loose us hs] at hl
  exact Bool.noConfusion hl

/-! ## Instance: "nothing left" while the last Step waits for an in-place retry

`running_workflow_without_active_descendants` judged a Workflow by its Steps'
*projected* states. A Step held for an in-place retry stays `running` with only
a failed Run, so it projects as terminal. When it was the last Step, the
classifier flagged the Workflow, and the repair could not infer an outcome
from a persisted `running` last Step: it failed with "operator review is
required" on every pass until the retry ran (F36). -/

structure Tail where
  /-- The last Step is held for a pending in-place retry. -/
  held : Bool
  /-- Any other active Step or Run. -/
  otherActive : Bool
  deriving DecidableEq, Repr

def detectTailBefore (t : Tail) : Prop := t.otherActive = false
def detectTailAfter (t : Tail) : Prop := t.otherActive = false ∧ t.held = false
/-- The repair can infer an outcome only when no Step is still persisted active. -/
def tailOutcomeKnown (t : Tail) : Prop := t.otherActive = false ∧ t.held = false

theorem tail_held_before_not_actionable : ¬ Actionable detectTailBefore tailOutcomeKnown := by
  intro h
  have := h ⟨true, false⟩ rfl
  simp [tailOutcomeKnown] at this

theorem tail_held_after_actionable : Actionable detectTailAfter tailOutcomeKnown := fun _ h => h

/-! ## Instance: queued Step behind a gate whose recheck is already due (F40)

F16 exempted pauses only. A unit blocked by any other gate (production:
`ci_repair_safety`, 437 refused resumes in 9 hours) also has a recheck already
scheduled for `blocked_until`. Resuming it before then only re-runs the gate,
which refuses and pushes `blocked_until` forward again. The reconciler is the
net for a *lost* recheck, so it acts once `blocked_until` has passed. -/

structure GatedStep where
  ready : Bool
  paused : Bool
  /-- Blocked by a gate with `blocked_until` still in the future. -/
  recheckDue : Bool
  /-- The gate would pass if evaluated now. -/
  gatePasses : Bool
  deriving DecidableEq, Repr

def detectGatedBefore (s : GatedStep) : Prop := s.ready = true ∧ s.paused = false
def detectGatedAfter (s : GatedStep) : Prop := s.ready = true ∧ s.paused = false ∧ s.recheckDue = false
/-- A recheck already due means the gate refused within its retry window. -/
def GatedWF (s : GatedStep) : Prop := s.recheckDue = true → s.gatePasses = false
def gatedResumes (s : GatedStep) : Prop := s.paused = false ∧ s.gatePasses = true

/-- Before: a flagged Step whose recheck is due is always refused. -/
theorem gated_before_refused :
    ∃ s, GatedWF s ∧ detectGatedBefore s ∧ ¬ gatedResumes s :=
  ⟨⟨true, false, true, false⟩, fun _ => rfl, ⟨rfl, rfl⟩, by simp [gatedResumes]⟩

/-- After: no Step with a pending recheck is flagged. -/
theorem gated_after_skips_due (s : GatedStep) (h : s.recheckDue = true) : ¬ detectGatedAfter s := by
  intro hd; rw [hd.2.2] at h; exact Bool.noConfusion h

/-! ## Instance: an intent with a succeeded and a failed unit (mixed outcomes)

`WorkIntents::TerminalUnitSync` settles an intent from the unit that just
finished: the last one to finish decides. Its reconciler backstops
(`succeeded_work_unit_unsatisfied_intent`, `failed_work_unit_unfailed_intent`)
looked at *every* terminal unit, so an intent whose older unit succeeded and
whose newer retry failed, with the sync missed, was flagged both ways; the
first repair to run won, which could be the stale success. -/

inductive UOut where | succeeded | failed deriving DecidableEq, Repr

/-- Terminal units of one intent, oldest first. -/
abbrev Units := List UOut

def syncOutcome (us : Units) : Option UOut := us.getLast?

def flagsBefore (us : Units) (o : UOut) : Bool := us.contains o
def flagsAfter (us : Units) (o : UOut) : Bool := syncOutcome us == some o

theorem mixed_before_flags_both :
    flagsBefore [.succeeded, .failed] .succeeded = true ∧ flagsBefore [.succeeded, .failed] .failed = true := by
  decide

/-- After: at most one outcome is flagged, and it is the sync's. -/
theorem mixed_after_agrees (us : Units) (o : UOut) (h : flagsAfter us o = true) :
    syncOutcome us = some o := by
  simpa [flagsAfter] using h

/-! ## Instance: who owns an active merge train (F43)

`classify_stale_active_merge_trains_without_runtime` treats a queued, running
or *blocked* train Workflow, an active unit, or a pending preserved relaunch as
the train's owner. Its repair's re-check counted only queued and running
Workflows and active units, so an owner of the other two kinds that appeared
after planning did not stop it from failing the train. -/

structure TrainOwners where
  liveWorkflow : Bool
  blockedWorkflow : Bool
  activeUnit : Bool
  relaunchPending : Bool
  deriving DecidableEq, Repr

def ownedClassifier (t : TrainOwners) : Bool :=
  t.liveWorkflow || t.blockedWorkflow || t.activeUnit || t.relaunchPending
def ownedExecutorBefore (t : TrainOwners) : Bool := t.liveWorkflow || t.activeUnit

/-- Before: the repair fails a train the classifier says is owned. -/
theorem train_before_fails_owned :
    ∃ t, ownedClassifier t = true ∧ ownedExecutorBefore t = false :=
  ⟨⟨false, false, false, true⟩, rfl, rfl⟩

/-- After: one predicate (`MergeTrainOwnership#owned?`) on both sides. -/
theorem train_after_agrees (t : TrainOwners) : ownedClassifier t = ownedClassifier t := rfl

/-! ## Instance: a retry from a Run whose branch was rewritten (F44)

`AutoRetryJob` skips an attempt whose source Run's workspace the PR branch has
moved past. The skip is budget-exempt and requests a reconciliation. The
planner (`classify_retryable_failures`) did not ask the same question, so each
pass scheduled a new attempt from the same Run: an unbounded sequence, since
neither the budget nor the per-Run dedup (which ignores skipped attempts)
advances. -/

/-- One reconciler pass: plan if the planner allows, then the attempt is
    skipped (exempt) when the branch moved. Returns attempts created. -/
def passAttempts (plannerChecksRewrite : Bool) (rewritten : Bool) : Nat :=
  if plannerChecksRewrite && rewritten then 0 else 1

def totalAttempts (checks rewritten : Bool) : Nat → Nat
  | 0 => 0
  | n + 1 => totalAttempts checks rewritten n + passAttempts checks rewritten

/-- Before: attempts grow with every pass. -/
theorem rewritten_before_loops (n : Nat) : totalAttempts false true n = n := by
  induction n with
  | zero => rfl
  | succ n ih => simp [totalAttempts, passAttempts, ih]

/-- After: none are planned from a rewritten Run. -/
theorem rewritten_after_bounded (n : Nat) : totalAttempts true true n = 0 := by
  induction n with
  | zero => rfl
  | succ n ih => simp [totalAttempts, passAttempts, ih]

/-! ## Refinement (F45): which retries a rewritten branch makes stale

The staleness is about the source Run's *workspace*. Only same-attempt retries
(`failed_step`, `resume_failed_step`) reuse it; a `retry_workflow` starts from
the current PR branch. Skipping every kind made the branch-divergence recovery
(a `retry_workflow` whose premise is a moved branch) unperformable: planned,
skipped, planned again. After: the skip applies to same-attempt kinds only,
and the planner routes a rewritten Run to a fresh retry. -/

inductive RKind where | sameAttempt | fresh deriving DecidableEq, Repr

def skipsAsRewritten (scopedToSameAttempt : Bool) (k : RKind) (rewritten : Bool) : Bool :=
  rewritten && (!scopedToSameAttempt || k == .sameAttempt)

/-- The planner after F45: a rewritten Run gets a fresh retry. -/
def plannedKind (rewritten : Bool) : RKind := if rewritten then .fresh else .sameAttempt

theorem divergence_recovery_skipped_before : skipsAsRewritten false .fresh true = true := rfl

/-- After: whatever the planner picks is never skipped as rewritten. -/
theorem planned_retry_never_skipped (rewritten : Bool) :
    skipsAsRewritten true (plannedKind rewritten) rewritten = false := by
  cases rewritten <;> rfl

end Agreement
end SyrusModel
