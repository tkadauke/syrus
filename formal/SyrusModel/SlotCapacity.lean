/-!
# Capacity soundness: who may occupy a concurrency slot

Two capacities gate work per repository:

* **Rebase slots.** `RebaseWorkflowSelector.active_in_repository` counts the
  rebase and stack-rebase WorkUnits of a repository, and `PollRebaseJob` /
  `PollMergeStateJob#repo_rebase_concurrency_reached?` decline every further
  rebase once that count reaches `CONCURRENT_REBASES_PER_REPO` (3).
* **Landing lanes.** A landing WorkUnit holds a lane's lock key;
  `WorkDefinitions.landing_capacity_full?` counts the lanes whose key an
  *active* (`queued`/`blocked`/`running`) landing unit holds, and
  `free_landing_lane_for` returns no lane once that count reaches the
  repository's `landing_concurrency`. Which blocked units still hold their
  lane is decided by `WorkUnit#block!`: it releases the `landing:` keys for an
  externally cleared reason (`manual_pause`, `no_capable_worker`,
  `agent_cannot_proceed`, `ci_repair_disabled`) and for any block before the
  Workflow's first Run (`prestart_landing_block?`, PrestartSlot.lean); every
  terminal transition releases all keys.

The production incident: rebase slots were counted over `ACTIVE_STATES`, so
three manually paused rebases held all three slots for days and no PR in the
repository could be rebased to land. The fix counts `RUNNABLE_STATES` only.

Proved here:

* `rebase_holder_runnable`: every unit counted against a rebase slot is
  `queued` or `running` -- a blocked, paused or finished unit never occupies
  one.
* `rebase_count_mono` / `demote_frees_rebase`: the count is monotone in the
  runnable holders, so blocking, pausing or finishing any unit never makes a
  slot *less* available.
* `paused_never_starve`: if no rebase unit of the repository is runnable, the
  cap is not reached (for any positive cap).
* `before_paused_starve` (counterexample to the old code): three manual pauses
  reach the cap under `ACTIVE_STATES`, and none under the fix.
* Landing lanes, `block_lane_sound` / `terminal_releases` / `lane_holder_sound`:
  every lane holder is runnable **or** an in-flight landing (past its first
  Run) blocked for a reason that is not externally cleared. A paused,
  prestart-blocked, no-capable-worker or finished unit never holds a lane.
* `inflight_blocked_holds_lane` (counterexample to the naive "every lane holder
  is runnable"): a landing blocked mid-flight on `provider_availability` keeps
  its lane, and with one lane `free_landing_lane_for` answers `nil` for every
  other approved Job. This is by design -- an in-flight landing keeps the lane
  so a second landing cannot overlap it on a moved base (LandingSlot.lean) --
  and it is live only under the fairness assumption stated at
  `LaneHoldingReasonsClear`: every lane-holding block reason has an automatic
  wake-up (a `blocked_until` recheck, or the landing queue's
  `release_*_blocked_landing_slots!` for `main_branch_health` and
  `urgent_job_active`). A new block reason that holds a lane and has no
  wake-up is exactly the rebase-slot bug again.
-/

namespace SyrusModel
namespace SlotCapacity

/-- `WorkUnit::STATES`. -/
inductive UState where
  | queued | running | blocked | succeeded | failed | cancelled
  deriving DecidableEq, Repr

/-- `WorkUnits::Ownership::RUNNABLE_STATES`. -/
def runnable : UState → Bool
  | .queued | .running => true
  | _ => false

/-- `WorkUnits::Ownership::ACTIVE_STATES`. -/
def active : UState → Bool
  | .queued | .running | .blocked => true
  | _ => false

theorem runnable_active {s : UState} (h : runnable s = true) : active s = true := by
  cases s <;> simp_all [runnable, active]

/-! ## Rebase slots -/

structure RUnit where
  repo : Nat
  /-- `kind ∈ RebaseWorkflowSelector::TRIGGER_KINDS`. -/
  rebaseKind : Bool
  /-- `workflow_id IS NOT NULL`. -/
  hasWorkflow : Bool
  state : UState
  deriving DecidableEq, Repr

/-- Counted by `RebaseWorkflowSelector.active_in_repository` (after the fix).
    One unit per Workflow is assumed, as in WorkUnits.lean, so the Ruby
    `unit_ids.uniq` does not change the count. -/
def holds (repo : Nat) (u : RUnit) : Bool :=
  runnable u.state && u.rebaseKind && u.repo == repo && u.hasWorkflow

/-- The same query before the fix: `ACTIVE_STATES`. -/
def holdsBefore (repo : Nat) (u : RUnit) : Bool :=
  active u.state && u.rebaseKind && u.repo == repo && u.hasWorkflow

def activeInRepository (us : List RUnit) (repo : Nat) : List RUnit := us.filter (holds repo)

def count (us : List RUnit) (repo : Nat) : Nat := (activeInRepository us repo).length
def countBefore (us : List RUnit) (repo : Nat) : Nat := (us.filter (holdsBefore repo)).length

/-- `PollRebaseJob::CONCURRENT_REBASES_PER_REPO`. -/
def cap : Nat := 3

/-- `repo_rebase_concurrency_reached?` (PollRebaseJob and PollMergeStateJob). -/
def concurrencyReached (c : Nat) (us : List RUnit) (repo : Nat) : Bool := decide (c ≤ count us repo)
def concurrencyReachedBefore (c : Nat) (us : List RUnit) (repo : Nat) : Bool := decide (c ≤ countBefore us repo)

/-- Every slot holder is runnable. -/
theorem rebase_holder_runnable {us : List RUnit} {repo : Nat} {u : RUnit}
    (h : u ∈ activeInRepository us repo) : runnable u.state = true := by
  unfold activeInRepository at h
  have := (List.mem_filter.mp h).2
  simp only [holds, Bool.and_eq_true] at this
  exact this.1.1.1

/-- A blocked or finished unit is never a slot holder. -/
theorem nonrunnable_never_holds {us : List RUnit} {repo : Nat} {u : RUnit}
    (h : runnable u.state = false) : u ∉ activeInRepository us repo := by
  intro hm
  have := rebase_holder_runnable hm
  rw [h] at this
  cases this

/-- Monotone in the holders: a change that never turns a non-holder into a
    holder never takes a slot. -/
theorem rebase_count_mono {repo : Nat} (f : RUnit → RUnit)
    (hf : ∀ u, holds repo (f u) = true → holds repo u = true) :
    ∀ us : List RUnit, count (us.map f) repo ≤ count us repo
  | [] => by simp [count, activeInRepository]
  | u :: rest => by
    have ih := rebase_count_mono f hf rest
    unfold count activeInRepository at ih ⊢
    rw [List.map_cons]
    by_cases hb : holds repo (f u) = true
    · have ha := hf u hb
      simp only [List.filter_cons, ha, hb, ite_true, List.length_cons]
      omega
    · simp only [List.filter_cons, hb]
      by_cases ha : holds repo u = true
      · simp only [ha, ite_true, List.length_cons]; simp only [Bool.false_eq_true, ite_false]; omega
      · simp only [Bool.false_eq_true, ite_false]; simp only [ha, Bool.false_eq_true, ite_false]; exact ih

/-- Blocking, pausing or finishing units never makes a rebase slot less
    available: `demote` moves the selected units to a non-runnable state. -/
def demote (p : RUnit → Bool) (to : UState) (u : RUnit) : RUnit :=
  if p u then { u with state := to } else u

theorem demote_frees_rebase (us : List RUnit) (repo : Nat) (p : RUnit → Bool) (to : UState)
    (hto : runnable to = false) : count (us.map (demote p to)) repo ≤ count us repo := by
  apply rebase_count_mono
  intro u h
  unfold demote at h
  by_cases hp : p u = true
  · simp [hp, holds, hto] at h
  · simpa [hp] using h

/-- No runnable rebase in the repository: the cap is not reached, however many
    paused or finished rebases there are. -/
theorem paused_never_starve (c : Nat) (hc : 0 < c) (us : List RUnit) (repo : Nat)
    (h : ∀ u ∈ us, u.repo = repo → u.rebaseKind = true → runnable u.state = false) :
    concurrencyReached c us repo = false := by
  have h0 : count us repo = 0 := by
    unfold count activeInRepository
    rw [List.length_eq_zero_iff, List.filter_eq_nil_iff]
    intro u hu hh
    simp only [holds, Bool.and_eq_true, beq_iff_eq] at hh
    have := h u hu hh.1.2 hh.1.1.2
    rw [this] at hh
    exact Bool.false_ne_true hh.1.1.1
  simp [concurrencyReached, h0]
  omega

/-- The incident: three manually paused rebases (two for weeks) filled every
    slot of the old count; under the fix they hold none. -/
theorem before_paused_starve :
    let paused : RUnit := { repo := 1, rebaseKind := true, hasWorkflow := true, state := .blocked }
    let us := [paused, paused, paused]
    concurrencyReachedBefore cap us 1 = true ∧ concurrencyReached cap us 1 = false := by
  decide

/-! ## Landing lanes -/

/-- `WorkUnit::BLOCKED_REASONS`, grouped by what `block!` does with the lane. -/
inductive Reason where
  | manualPause | noCapableWorker | agentCannotProceed | ciRepairDisabled
  | providerAvailability | admissionControl | resourceSafety | mainBranchHealth
  | urgentJobActive | autoRetryBackoff | other
  deriving DecidableEq, Repr

/-- `WorkUnit::EXTERNALLY_CLEARED_BLOCKED_REASONS`. -/
def externallyCleared : Reason → Bool
  | .manualPause | .noCapableWorker | .agentCannotProceed | .ciRepairDisabled => true
  | _ => false

structure LUnit where
  state : UState
  reason : Option Reason
  /-- The Workflow has its first Run (`¬ queued_landing_before_first_run?`). -/
  started : Bool
  /-- Holds an unreleased lane lock (`landing:` key). -/
  holdsLane : Bool
  deriving DecidableEq, Repr

/-- `WorkUnit#block!`: release the landing keys for an externally cleared
    reason or a block before the first Run. -/
def block (u : LUnit) (r : Reason) : LUnit :=
  { u with state := .blocked, reason := some r,
           holdsLane := if externallyCleared r || !u.started then false else u.holdsLane }

/-- `mark_terminal!` / `preempt!`: every lock is released. -/
def terminate (u : LUnit) (s : UState) : LUnit :=
  { u with state := s, reason := none, holdsLane := false }

/-- `mark_running!` / `resume_for_workflow!`: `ensure_active_locks!` (re)takes
    the lane when it is free. -/
def resume (u : LUnit) (laneFree : Bool) (s : UState) : LUnit :=
  { u with state := s, reason := none, holdsLane := u.holdsLane || laneFree }

/-- A lane holder is runnable, or an in-flight landing blocked for a reason that
    is not externally cleared. -/
def LaneSound (u : LUnit) : Prop :=
  u.holdsLane = true →
    runnable u.state = true ∨
      (u.state = .blocked ∧ u.started = true ∧ ∃ r, u.reason = some r ∧ externallyCleared r = false)

theorem block_lane_sound (u : LUnit) (r : Reason) : LaneSound (block u r) := by
  intro h
  right
  unfold block at h ⊢
  cases hx : externallyCleared r <;> cases hs : u.started <;> simp_all

theorem terminal_releases (u : LUnit) (s : UState) : (terminate u s).holdsLane = false := rfl

theorem resume_lane_sound (u : LUnit) (laneFree : Bool) (s : UState) (hs : runnable s = true) :
    LaneSound (resume u laneFree s) := fun _ => Or.inl hs

/-- A paused (or otherwise externally cleared) unit never holds a lane. -/
theorem paused_releases_lane (u : LUnit) (r : Reason) (h : externallyCleared r = true) :
    (block u r).holdsLane = false := by
  simp [block, h]

/-- Nor does a landing blocked before its first Run. -/
theorem prestart_releases_lane (u : LUnit) (r : Reason) (h : u.started = false) :
    (block u r).holdsLane = false := by
  simp [block, h]

/-- The lifecycle operations of one unit. -/
inductive Op where
  | block (r : Reason)
  | terminate (s : UState) (hs : runnable s = false ∧ s ≠ .blocked)
  | resume (laneFree : Bool) (s : UState) (hs : runnable s = true)

def apply (u : LUnit) : Op → LUnit
  | .block r => block u r
  | .terminate s _ => terminate u s
  | .resume f s _ => resume u f s

/-- Every operation leaves the unit lane-sound, whatever it held before. -/
theorem apply_lane_sound (u : LUnit) : ∀ op, LaneSound (apply u op)
  | .block r => block_lane_sound u r
  | .terminate s _ => by intro h; simp [apply, terminate] at h
  | .resume f s hs => resume_lane_sound u f s hs

/-- So every unit the lifecycle produces from a lane-sound start (a fresh unit
    holds no lane) is lane-sound. -/
theorem lane_holder_sound : ∀ (ops : List Op) (u : LUnit), LaneSound u → LaneSound (ops.foldl apply u)
  | [], _, h => h
  | op :: ops, u, _ => lane_holder_sound ops (apply u op) (apply_lane_sound u op)

theorem fresh_lane_sound (u : LUnit) (hu : u.holdsLane = false) : LaneSound u := by
  intro h; rw [hu] at h; cases h

/-- `landing_capacity_full?`: lanes occupied by active landing units. -/
def occupied (us : List LUnit) : Nat := (us.filter fun u => u.holdsLane && active u.state).length

/-- `free_landing_lane_for` is nil exactly when capacity is full. -/
def capacityFull (lanes : Nat) (us : List LUnit) : Bool := decide (lanes ≤ occupied us)

/-- A counted lane holder is runnable or in flight with a lane-holding reason. -/
theorem lane_count_sound (us : List LUnit) (hs : ∀ u ∈ us, LaneSound u) :
    ∀ u ∈ us.filter (fun u => u.holdsLane && active u.state),
      runnable u.state = true ∨
        (u.state = .blocked ∧ u.started = true ∧ ∃ r, u.reason = some r ∧ externallyCleared r = false) := by
  intro u hu
  have hm := List.mem_filter.mp hu
  simp only [Bool.and_eq_true] at hm
  exact hs u hm.1 hm.2.1

/-- Counterexample to "every lane holder is runnable": a landing blocked
    mid-flight on `provider_availability` keeps its lane, so with one lane the
    capacity is full and no other approved Job gets a lane. -/
theorem inflight_blocked_holds_lane :
    let fresh : LUnit := { state := .running, reason := none, started := true, holdsLane := true }
    let u := block fresh .providerAvailability
    u.holdsLane = true ∧ runnable u.state = false ∧ capacityFull 1 [u] = true := by
  decide

/-- The same unit paused by an operator gives the lane back. -/
theorem paused_inflight_frees_lane :
    let fresh : LUnit := { state := .running, reason := none, started := true, holdsLane := true }
    capacityFull 1 [block fresh .manualPause] = false := by
  decide

/-- **Fairness assumption** for lane liveness: every reason that keeps a lane has
    an automatic wake-up (`provider_availability` and `admission_control`
    recheck at their `retry_at`; `auto_retry_backoff` at `blocked_until`;
    `main_branch_health` and `urgent_job_active` are released by the landing
    queue for the repair or urgent Job). Stated, not proved: it is a property
    of the wake-up jobs, outside this model. -/
def LaneHoldingReasonsClear (eventuallyClears : Reason → Prop) : Prop :=
  ∀ r, externallyCleared r = false → eventuallyClears r

end SlotCapacity
end SyrusModel
