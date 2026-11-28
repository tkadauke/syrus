/-!
# Retry termination under a fixed failure classification

Two automatic loops retry a failure without an operator:

1. **The auto-retry ladder.** The reconciler plans a retry only while
   `RepairPlanner::Policies::Base#retry_budget_available?`, and
   `RepairExecutor::Policies::Base#schedule_auto_retry!` numbers the attempt by
   `AutoRetryAttempt.budget_scope_for(job, provider, classification).count + 1`
   and refuses past `retry_budget_limit_for(classification)` (3, or 20 for
   `worker_died`). An attempt is charged unless it is skipped with a reason in
   `BUDGET_EXEMPT_SKIPPED_REASON_PREFIXES`. The model treats admissions as a
   sequence: each one sees every attempt admitted before it. The Ruby makes
   that true by counting under the Workflow's ancestry lock with a locking
   read, since a plain read would answer from the REPEATABLE READ snapshot
   fixed before the lock was granted and miss a concurrent admission.
2. **The landing deferral.** A landing that fails with a transient blocker
   (`LandingFailureCode::TRANSIENT_BLOCKER`: a 502, a dead worker, a prepare
   that did not build, or any retryable classification) is deferred: the Job
   keeps its approval and `LandingQueueProcessor#land` launches it again on
   the next tick. This path has no budget of its own; the only bound is the
   Job's runaway limits (`Job#enforce_workflow_runaway_limits!`: 10
   consecutive failed Workflows, 50 in total), and those return early once
   `runaway_protection` is set.

Proved here:

* `ladder_charged_bound` / `ladder_length_bound`: any sequence of attempts the
  executor admits charges at most `limit` of them, so it has at most
  `limit + e` attempts when `e` of them were budget-exempt skips.
* `fixed_classification_no_change_skip` / `fixed_provider_no_change_skip`: the
  two exempt reasons that report a change (`failure classification changed`,
  `default provider changed`) are written only when the classification or
  provider did change. With both fixed, the only exempt skips left are
  environmental (provider unavailable or degraded, a branch that moved) or
  final (job terminal, workflow superseded, after which nothing is planned).
  **Fairness assumption:** those environmental conditions occur finitely often
  for one failure. Under it the ladder terminates.
* `before_ladder_unbounded` (the earlier bug, kept as a counterexample): when
  the non-retryable recheck wrote an exempt "classification changed" reason
  for a classification that had not changed, every attempt was free and the
  executor admits a sequence of any length.
* **Counterexample, found by this model** (`before_landing_loops`): a
  runaway-protected Job that an operator approved, whose landing fails the same
  way every time with a transient-blocker classification, cycles
  `approved → landing → approved` forever. The runaway limits do not fire again
  (they return early once the flag is set), `LandingFailureHandler` defers,
  and `LandingQueueProcessor#land` relaunches. Production showed a direct Job
  relaunching its `auto_merge` every few minutes for hours with a prepare
  step failing as `provider_transient`/`timeout`.
* **Counterexample, the two loops multiplied** (`before_identical_failures`):
  the dispatcher's in-place rerun (`INFRASTRUCTURE_STEP_RETRY_LIMIT` = 2 per
  Workflow) and the ladder (`MAX_ATTEMPTS` = 3 fresh Workflows) each had a
  budget of its own, so a deterministic timeout failed `3 * 4 = 12` times,
  past the `retry_storms` invariant's threshold of 5.
* After the fix both loops consult `Runs::RepeatedFailure`, one budget per
  (Job, step kind, failure fingerprint): neither retries once the Job has
  failed that step that way `maxIdentical` times, and an in-place rerun also
  stops once it repeated the Run before it. Under a fixed fingerprint every
  performed retry adds one identical failure, so `identical_retries_bound`:
  at most `maxIdentical` identical failures in total, without the fairness
  assumption the ladder needs for exempt skips (a skip performs nothing and
  adds no failure). `after_identical_below_storm`: that is below the storm
  threshold.
* **Counterexample, outages** (`before_outage_held`): the identical-failure
  budget also counted an external outage (`github_api_transient`,
  `provider_transient`, `prepare_network_transient`), which repeats
  identically by nature, so any outage longer than about five minutes ended
  at an operator hold.
* After that fix outages are exempt from the identical-failure budget and
  the repeated-failure circuit. The ladder admits an outage retry only while
  the outage is younger than `OUTAGE_RETRY_HORIZON` (`outageAdmitted`) and
  under the `MAX_OUTAGE_ATTEMPTS` backstop; every attempt waits at least the
  first backoff. `outage_attempts_bound`: at most `maxOutageAttempts`
  attempts whatever the clock does, and `outage_attempts_time_bound`: at
  most `horizon / minBackoff + 1` within the horizon. `outage_failures_bound`:
  with the in-place reruns, at most `outageFailureCap` failures, below the
  `retry_storms` invariant's `outage_max_failures` -- so the policy never
  produces what the invariant calls an outage storm, and an outage outlives
  the old ladder (`outage_outlasts_old_ladder`).
* After the fix (`LandingFailureHandler#runaway_retry_refused?`: a transient
  failure of a runaway-protected Job fails the landing back to `implemented`):
  `after_step_decreases` gives a ranking function, so `after_terminates`:
  from any state the automatic loop stops within `rank s ≤ 32` steps, and
  `after_stops_named`: from an approved Job it stops with runaway protection
  set and the Job `failed` or `implemented` -- a named blocker, never a silent
  wait.
* **Counterexample, merge trains** (`before_train_loops`): the same promise
  leaked through train dispatch. `MergeTrainDispatcher.try_dispatch!` (and
  `JobBundleDispatcher`) launch through `WorkUnits::Launcher.instantiate`,
  which never consults the `RunawayProtection` intent gate, and a failed train
  defers its members back to `approved` on paths that never reach
  `LandingFailureHandler#runaway_retry_refused?` (a rebuild-required base move,
  a teardown, an agent withdrawing another member). The reconciler's
  `rebuild_merge_train` repair and the landing queue then relaunched the train
  forever.
* After the fix (`MergeTrains::RunawayHold`, consulted by both dispatchers'
  `runaway_hold_reason`): one automatic train attempt per operator consent.
  `after_train_stops`: from an approved runaway-protected member the automatic
  train loop stops within two steps, held with the named reason
  (`TrainHeld`), and `consent_buys_one_attempt`: an operator's approval
  enables exactly one more dispatch.
-/

namespace SyrusModel
namespace RetryTermination

/-! ## The auto-retry ladder -/

/-- `BUDGET_EXEMPT_SKIPPED_REASON_PREFIXES`. -/
inductive Exempt where
  | agentUnavailable | providerDegraded | jobTerminal | superseded
  | classificationChanged | defaultProviderChanged | branchDivergenceRecovered | branchRewritten
  deriving DecidableEq, Repr

/-- What happened to one admitted attempt. -/
inductive Outcome where
  /-- `performed_at` set. -/
  | performed
  /-- Skipped for a reason that is charged (`failure is not retryable`,
      `source step already recovered`, an execution failure, ...). -/
  | charged
  | exempt (r : Exempt)
  deriving DecidableEq, Repr

def charges : Outcome → Bool
  | .exempt _ => false
  | _ => true

def chargedCount (os : List Outcome) : Nat := (os.filter charges).length
def exemptCount (os : List Outcome) : Nat := (os.filter (fun o => !charges o)).length

/-- The executor admits each attempt with number `charged + 1 ≤ limit`. -/
def Admitted (limit : Nat) : Nat → List Outcome → Prop
  | _, [] => True
  | c, o :: os => c + 1 ≤ limit ∧ Admitted limit (if charges o then c + 1 else c) os

theorem ladder_charged_bound (limit : Nat) :
    ∀ (c : Nat) (os : List Outcome), c ≤ limit → Admitted limit c os → c + chargedCount os ≤ limit
  | c, [], hc, _ => by simpa [chargedCount] using hc
  | c, o :: os, _, ⟨hle, hrest⟩ => by
    cases ho : charges o
    · have := ladder_charged_bound limit c os (by omega) (by simpa [ho] using hrest)
      simp [chargedCount, ho] at this ⊢; omega
    · have := ladder_charged_bound limit (c + 1) os hle (by simpa [ho] using hrest)
      simp [chargedCount, ho] at this ⊢; omega

theorem length_split (os : List Outcome) : os.length = chargedCount os + exemptCount os := by
  induction os with
  | nil => rfl
  | cons o os ih =>
    simp only [chargedCount, exemptCount, List.filter_cons, List.length_cons] at ih ⊢
    cases charges o <;> simp <;> omega

/-- At most `limit` charged attempts, plus however many were exempt. -/
theorem ladder_length_bound (limit : Nat) (os : List Outcome) (h : Admitted limit 0 os) :
    os.length ≤ limit + exemptCount os := by
  have := ladder_charged_bound limit 0 os (Nat.zero_le _) h
  rw [length_split]; omega

/-- `AutoRetryJob#skip_if_provider_delay_no_longer_matches`: the only writer of
    "failure classification changed". -/
def classificationSkip {C : Type} [DecidableEq C] (attempt fresh : C) : Option Exempt :=
  if fresh = attempt then none else some .classificationChanged

/-- `AutoRetryJob#skip_if_default_provider_changed`: the only writer of
    "default provider changed". -/
def providerSkip {P : Type} [DecidableEq P] (attempt desired : P) : Option Exempt :=
  if desired = attempt then none else some .defaultProviderChanged

theorem fixed_classification_no_change_skip {C : Type} [DecidableEq C] (c : C) :
    classificationSkip c c = none := by simp [classificationSkip]

theorem fixed_provider_no_change_skip {P : Type} [DecidableEq P] (p : P) :
    providerSkip p p = none := by simp [providerSkip]

/-- The earlier `skip_if_failure_no_longer_retryable` wrote the exempt
    "classification changed" reason for every non-retryable verdict, so a
    never-retryable failure charged nothing: the executor admits it forever. -/
theorem before_ladder_unbounded (limit : Nat) (hl : 0 < limit) :
    ∀ n, Admitted limit 0 (List.replicate n (.exempt .classificationChanged)) := by
  intro n
  induction n with
  | zero => trivial
  | succ n ih => exact ⟨by omega, by simpa [charges] using ih⟩

/-! ## The landing deferral loop -/

inductive JS where
  | approved | landing | implemented | failed
  deriving DecidableEq, Repr

structure L where
  job : JS
  /-- `consecutive_failed_workflows_count`. -/
  streak : Nat
  /-- `workflows_since_latest_reopen.count`. -/
  total : Nat
  runaway : Bool
  deriving DecidableEq, Repr

/-- `Job::MAX_CONSECUTIVE_FAILED_WORKFLOWS`, `Job::MAX_TOTAL_WORKFLOWS`. -/
def maxStreak : Nat := 10
def maxTotal : Nat := 50

/-- `LandingQueueProcessor#land`: launch an approved Job's landing. It does not
    consult `runaway_protection`. On create, `enforce_workflow_runaway_limits!`
    trips at `maxTotal` unless the flag is already set. -/
def land (s : L) : L :=
  let t := s.total + 1
  if !s.runaway && maxTotal ≤ t then { s with total := t, runaway := true, job := .failed }
  else { s with total := t, job := .landing }

/-- The landing fails with a transient blocker. `enforce_workflow_runaway_limits!`
    (failed workflow) trips at `maxStreak` unless the flag is set; otherwise
    `LandingFailureHandler` defers (before) or, for a runaway-protected Job,
    fails the landing (after the fix). -/
def failTransient (fixed : Bool) (s : L) : L :=
  let k := s.streak + 1
  if !s.runaway && maxStreak ≤ k then { s with streak := k, runaway := true, job := .failed }
  else if fixed && s.runaway then { s with streak := k, job := .implemented }
  else { s with streak := k, job := .approved }

/-- One automatic step; `none` when nothing automatic is enabled. -/
def auto (fixed : Bool) (s : L) : Option L :=
  match s.job with
  | .approved => some (land s)
  | .landing => some (failTransient fixed s)
  | _ => none

/-- One full automatic cycle from an approved Job. -/
def cycle (fixed : Bool) (s : L) : L := failTransient fixed (land s)

def iter (f : L → L) : Nat → L → L
  | 0, s => s
  | n + 1, s => iter f n (f s)

/-- The counterexample: an operator approved a runaway-protected Job, and its
    landing keeps failing as transient. Every cycle ends approved again. -/
theorem before_landing_loops :
    ∀ (n : Nat) (s : L), s.runaway = true → s.job = .approved →
      (iter (cycle false) n s).job = .approved ∧ (iter (cycle false) n s).runaway = true
  | 0, _, hr, ha => ⟨ha, hr⟩
  | n + 1, s, hr, _ => by
    apply before_landing_loops n
    · simp [cycle, failTransient, land, hr]
    · simp [cycle, failTransient, land, hr]

/-- The production state: 50 workflows and the flag already set. -/
theorem before_landing_loops_concrete :
    let s : L := { job := .approved, streak := 12, total := 60, runaway := true }
    auto false s = some { s with job := .landing, total := 61 } ∧
      auto false { s with job := .landing, total := 61 } = some { s with streak := 13, total := 61 } := by
  decide

/-- The ranking function for the fixed loop. -/
def rank (s : L) : Nat :=
  match s.job with
  | .approved => if s.runaway then 2 else 3 * (maxStreak - s.streak) + 2
  | .landing => if s.runaway then 1 else 3 * (maxStreak - s.streak) + 1
  | _ => 0

theorem land_decreases (s : L) (hj : s.job = .approved) : rank (land s) < rank s := by
  by_cases hr : s.runaway = true <;> by_cases ht : maxTotal ≤ s.total + 1 <;>
    simp [land, rank, hj, hr, ht] <;> omega

theorem fail_decreases (s : L) (hj : s.job = .landing) : rank (failTransient true s) < rank s := by
  by_cases hr : s.runaway = true
  · simp [failTransient, rank, hj, hr]
  · by_cases hk : maxStreak ≤ s.streak + 1
    · simp [failTransient, rank, hj, hr, hk]
    · simp [failTransient, rank, hj, hr, hk]; simp [maxStreak] at hk ⊢; omega

theorem after_step_decreases (s t : L) (h : auto true s = some t) : rank t < rank s := by
  unfold auto at h
  cases hj : s.job <;> rw [hj] at h <;> simp only [Option.some.injEq, reduceCtorEq] at h <;> subst h
  · exact land_decreases s hj
  · exact fail_decreases s hj

/-- Run the automatic loop with fuel. -/
def run (fixed : Bool) : Nat → L → L
  | 0, s => s
  | n + 1, s => match auto fixed s with
    | none => s
    | some t => run fixed n t

theorem rank_pos_of_auto (s t : L) (h : auto true s = some t) : 0 < rank s := by
  have := after_step_decreases s t h; omega

/-- Termination: after `rank s` automatic steps nothing automatic is enabled. -/
theorem after_terminates : ∀ (n : Nat) (s : L), rank s ≤ n → auto true (run true n s) = none
  | 0, s, h => by
    cases ha : auto true s with
    | none => simpa [run] using ha
    | some t => have := rank_pos_of_auto s t ha; omega
  | n + 1, s, h => by
    cases ha : auto true s with
    | none => simp [run, ha]
    | some t =>
      simp only [run, ha]
      exact after_terminates n t (by have := after_step_decreases s t ha; omega)

theorem rank_le (s : L) : rank s ≤ 3 * maxStreak + 2 := by
  unfold rank; split <;> (try split) <;> omega

/-- Invariant: the loop only stops a Job with runaway protection set. -/
def StopNamed (s : L) : Prop := (s.job = .failed ∨ s.job = .implemented) → s.runaway = true

theorem auto_named (s t : L) (h : auto true s = some t) : StopNamed t := by
  unfold auto at h
  cases hj : s.job <;> rw [hj] at h <;> simp only [Option.some.injEq, reduceCtorEq] at h <;> subst h
  · by_cases hr : s.runaway = true <;> by_cases ht : maxTotal ≤ s.total + 1 <;>
      simp [StopNamed, land, hr, ht]
  · by_cases hr : s.runaway = true <;> by_cases hk : maxStreak ≤ s.streak + 1 <;>
      simp [StopNamed, failTransient, hr, hk]

theorem run_named : ∀ (n : Nat) (s : L), StopNamed s → StopNamed (run true n s)
  | 0, _, h => h
  | n + 1, s, h => by
    cases ha : auto true s with
    | none => simpa [run, ha] using h
    | some t => simp only [run, ha]; exact run_named n t (auto_named s t ha)

theorem stopped_job (e : L) (h : auto true e = none) : e.job = .failed ∨ e.job = .implemented := by
  unfold auto at h
  cases hj : e.job <;> rw [hj] at h <;> simp_all

/-- From an approved Job the fixed loop stops within `rank s` steps, at a Job
    that is failed or implemented with runaway protection set. -/
theorem after_stops_named (s : L) (ha : s.job = .approved) :
    auto true (run true (rank s) s) = none ∧
      ((run true (rank s) s).job = .failed ∨ (run true (rank s) s).job = .implemented) ∧
      (run true (rank s) s).runaway = true := by
  have hstop := after_terminates (rank s) s (Nat.le_refl _)
  have hnamed := run_named (rank s) s (by intro h; rw [ha] at h; cases h <;> rename_i h <;> cases h)
  have hjob := stopped_job _ hstop
  exact ⟨hstop, hjob, hnamed hjob⟩

/-! ## The merge-train loop of a runaway-protected member -/

/-- One runaway-protected member of an Epic merge train (or job bundle). -/
structure T where
  /-- `true` while the member is approved and waiting for its train. -/
  approved : Bool
  /-- `true` while a train containing it is landing. -/
  landing : Bool
  /-- `MergeTrains::RunawayHold.failed_train_since_consent`: a train
      containing the member failed since an operator last approved it. -/
  spent : Bool
  /-- How many trains were dispatched. -/
  trains : Nat
  deriving DecidableEq, Repr

/-- `runaway_hold_reason` is present: the member is runaway-protected (the
    whole section is about such a member) and its consent is spent. -/
def held (fixed : Bool) (s : T) : Bool := fixed && s.spent

/-- One automatic step: the dispatcher launches the train, or the train fails
    with a reason that defers its members back to `approved`. -/
def trainAuto (fixed : Bool) (s : T) : Option T :=
  if s.landing then some { s with landing := false, approved := true, spent := true }
  else if s.approved && !held fixed s then some { s with approved := false, landing := true, trains := s.trains + 1 }
  else none

/-- An operator approves the member again (`approved_by_user`). -/
def operatorApprove (s : T) : T := { s with approved := true, spent := false }

def trainIter (fixed : Bool) : Nat → T → T
  | 0, s => s
  | n + 1, s => match trainAuto fixed s with
    | none => s
    | some t => trainIter fixed n t

/-- Without the hold, two automatic steps dispatch a train and defer the
    member back to `approved`. -/
theorem before_two_steps (s : T) (ha : s.approved = true) (hl : s.landing = false) (k : Nat) :
    trainIter false (k + 2) s =
      trainIter false k { s with approved := true, landing := false, spent := true, trains := s.trains + 1 } := by
  obtain ⟨a, l, sp, n⟩ := s
  simp only at ha hl
  subst ha; subst hl
  simp [trainIter, trainAuto, held]

/-- The counterexample: without the hold every two automatic steps dispatch
    another train, so the number of trains grows without bound. -/
theorem before_train_loops : ∀ (n : Nat) (s : T), s.approved = true → s.landing = false →
    (trainIter false (2 * n) s).trains = s.trains + n ∧ (trainIter false (2 * n) s).approved = true
  | 0, _, ha, _ => ⟨by simp [trainIter], by simpa [trainIter] using ha⟩
  | n + 1, s, ha, hl => by
    rw [show 2 * (n + 1) = 2 * n + 2 by omega, before_two_steps s ha hl]
    have ih := before_train_loops n { s with approved := true, landing := false, spent := true, trains := s.trains + 1 } rfl rfl
    refine ⟨?_, ih.2⟩
    rw [ih.1]; dsimp only; omega

/-- The member is held with the named reason. -/
def TrainHeld (s : T) : Prop := s.approved = true ∧ s.landing = false ∧ held true s = true

/-- After the fix: from an approved member (consent unspent or spent), the
    automatic loop stops within two steps, held with a named reason, having
    dispatched at most one train. -/
theorem after_train_stops (s : T) (ha : s.approved = true) (hl : s.landing = false) :
    trainAuto true (trainIter true 2 s) = none ∧ TrainHeld (trainIter true 2 s) ∧
      (trainIter true 2 s).trains ≤ s.trains + 1 := by
  obtain ⟨a, l, sp, n⟩ := s
  simp only at ha hl
  subst ha; subst hl
  cases sp <;> simp [trainIter, trainAuto, held, TrainHeld]

/-- An operator's approval buys exactly one more automatic train. -/
theorem consent_buys_one_attempt (s : T) (hl : s.landing = false) :
    (trainIter true 2 (operatorApprove s)).trains = s.trains + 1 ∧
      trainAuto true (trainIter true 2 (operatorApprove s)) = none := by
  obtain ⟨a, l, sp, n⟩ := s
  simp only at hl
  subst hl
  simp [operatorApprove, trainIter, trainAuto, held]

/-! ## The shared identical-failure budget -/

/-- `Runs::RepeatedFailure::MAX_IDENTICAL_FAILURES`. -/
def maxIdentical : Nat := 4
/-- The `retry_storms` invariant's default `max_failures`: more is a storm. -/
def stormThreshold : Nat := 5
/-- `StepDispatcher::INFRASTRUCTURE_STEP_RETRY_LIMIT`, `AutoRetryAttempt::MAX_ATTEMPTS`. -/
def inPlaceLimit : Nat := 2
def ladderLimit : Nat := 3

/-- Before: every Workflow attempt reran its Step in place to the limit, and
    the ladder started a fresh Workflow to its own limit. -/
def beforeIdenticalFailures : Nat := (inPlaceLimit + 1) * (ladderLimit + 1)

theorem before_identical_failures :
    beforeIdenticalFailures = 12 ∧ stormThreshold < beforeIdenticalFailures := by decide

/-- `n` performed retries -- in place (`stop_in_place?` false) or a fresh
    Workflow (`budget_exhausted?` false) -- from `f` identical failures. Each
    is admitted only while `f < maxIdentical` and, the fingerprint being
    fixed, ends in one more identical failure. -/
def AdmittedRetries : Nat → Nat → Prop
  | _, 0 => True
  | f, n + 1 => f < maxIdentical ∧ AdmittedRetries (f + 1) n

theorem identical_retries_bound : ∀ (n f : Nat), f ≤ maxIdentical → AdmittedRetries f n → f + n ≤ maxIdentical
  | 0, _, hf, _ => by simpa using hf
  | n + 1, f, _, ⟨hlt, hrest⟩ => by
    have := identical_retries_bound n (f + 1) (by omega) hrest
    omega

/-- From the first failure, at most `maxIdentical` identical failures in all,
    below the storm threshold. -/
theorem after_identical_below_storm (n : Nat) (h : AdmittedRetries 1 n) :
    1 + n ≤ maxIdentical ∧ 1 + n ≤ stormThreshold := by
  have := identical_retries_bound n 1 (by decide) h
  exact ⟨this, by simp [maxIdentical, stormThreshold] at this ⊢; omega⟩

/-! ## External outages: bounded by time, not by count -/

/-- `AutoRetryAttempt::MAX_OUTAGE_ATTEMPTS`, the backstop. -/
def maxOutageAttempts : Nat := 8
/-- `OUTAGE_RETRY_HORIZON` and the shortest `OUTAGE_BACKOFFS` step, in minutes. -/
def horizon : Nat := 90
def minBackoff : Nat := 5
/-- The `retry_storms` invariant's `outage_max_failures` default. -/
def outageStormThreshold : Nat := 30

/-- Before: the identical-failure budget held an outage once it had failed
    `maxIdentical` times, however young it was. -/
def beforeOutageAdmitted (failures : Nat) : Bool := decide (failures < maxIdentical)

theorem before_outage_held : beforeOutageAdmitted maxIdentical = false := by decide

/-- `RepairPlanner#retry_budget_available?` for an outage: the attempt
    number is under the backstop and `outage_retry_window_open?` (the
    outage, `elapsed` minutes old, is younger than the horizon). -/
def outageAdmitted (attempts elapsed : Nat) : Bool :=
  decide (attempts < maxOutageAttempts) && decide (elapsed < horizon)

/-- A sequence of admitted attempts; each waits at least `minBackoff`. -/
def OutageLadder : Nat → Nat → Nat → Prop
  | _, _, 0 => True
  | a, t, n + 1 => outageAdmitted a t = true ∧ ∀ w, minBackoff ≤ w → OutageLadder (a + 1) (t + w) n

/-- The backstop: never more than `maxOutageAttempts` attempts. -/
theorem outage_attempts_bound :
    ∀ (n a t : Nat), a ≤ maxOutageAttempts → OutageLadder a t n → a + n ≤ maxOutageAttempts
  | 0, _, _, ha, _ => by simpa using ha
  | n + 1, a, t, _, ⟨hadm, hrest⟩ => by
    simp only [outageAdmitted, Bool.and_eq_true, decide_eq_true_eq] at hadm
    have := outage_attempts_bound n (a + 1) (t + minBackoff) (by omega) (hrest minBackoff (Nat.le_refl _))
    omega

/-- The horizon: with even the shortest waits, the last of `n + 1`
    admitted attempts starts inside the horizon, so an outage gets at most
    `horizon / minBackoff + 1` attempts. -/
theorem outage_attempts_time_bound :
    ∀ (n a t : Nat), OutageLadder a t (n + 1) → t + minBackoff * n < horizon
  | 0, _, t, ⟨hadm, _⟩ => by
    simp only [outageAdmitted, Bool.and_eq_true, decide_eq_true_eq] at hadm
    simpa using hadm.2
  | n + 1, a, t, ⟨_, hrest⟩ => by
    have := outage_attempts_time_bound n (a + 1) (t + minBackoff) (hrest minBackoff (Nat.le_refl _))
    simp only [minBackoff, horizon] at this ⊢
    omega

/-- Each attempt's Workflow reruns the step in place at most `inPlaceLimit`
    times, so an outage fails at most this many times in all. -/
def outageFailureCap : Nat := (inPlaceLimit + 1) * (maxOutageAttempts + 1)

theorem outage_failures_bound : outageFailureCap = 27 ∧ outageFailureCap < outageStormThreshold := by decide

/-- The old ladder gave an outage `ladderLimit` attempts; the outage ladder
    admits more while the outage is young. -/
theorem outage_outlasts_old_ladder : outageAdmitted ladderLimit (ladderLimit * 20) = true ∧ ladderLimit < maxOutageAttempts := by
  decide

end RetryTermination
end SyrusModel
