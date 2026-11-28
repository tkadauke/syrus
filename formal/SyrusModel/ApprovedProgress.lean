import SyrusModel.SlotCapacity

/-!
# Progress of approved work: land, or say why not

An approved Job should either land or carry a reason it cannot. The incidents
this models were silent: the Job's landing-queue entry had no
`blocked_reason`, and still nothing happened.

**The model** is one approved Job `J` in a repository:

* `blocker`: `LandingQueueProcessor#blockage_for(J)` returned a named reason.
* `needsRebase`: GitHub reports `behind`/`dirty`, so
  `LandingQueueProcessor#mergeability_admits_landing?` refuses and `land`
  rolls back, leaving the rebase to `PollMergeStateJob`. Nothing in
  `blockage_for` names this state.
* `own`: `J`'s own rebase WorkUnit, if any (`blockage_for` then reports
  `active_workflow`, and a paused one carries its own `blocked_reason`).
* `others`: the other rebase units of the repository, counted against
  `CONCURRENT_REBASES_PER_REPO` by `repo_rebase_concurrency_reached?`.
* `lanes`: the units occupying `J`'s landing lanes (SlotCapacity.lean); `J`
  gets no lane while `landing_capacity_full?`.

Steps (all automatic): `land` (the queue launches `J`), `dispatch`
(`PollMergeStateJob` starts `J`'s rebase), and a runnable unit finishing
(`J`'s rebase, another rebase, a lane holder). A blocked unit never moves on
its own -- clearing a pause is an operator action and clearing any other block
reason is a wake-up outside this model.

`Named s`: `J` has a blocker, an own rebase unit, or a full lane held by a
*blocked* unit (which carries its reason, SlotCapacity.lean).

Proved here:

* `no_silent_stall`: after the rebase-slot fix, every approved state that is
  not `Named` has an enabled step.
* `before_silent_stall` (the incident): with slots counted over
  `ACTIVE_STATES`, three paused rebases of other Jobs leave `J` with no
  blocker, no enabled step and nothing naming why.
* `step_decreases`: `rank` strictly decreases on every step, and
  `eventually_lands_or_named`: from any approved state every maximal run is
  at most `rank s` steps long and ends with `J` landing or `Named`.

**Fairness assumptions** (stated, not modelled): (F1) an enabled step is
eventually taken -- the landing queue and the merge-state and rebase polls run
periodically; (F2) while `J` waits, no new competing rebase or landing is
admitted ahead of it (the model has no such step; in production the rebase
slots are not allocated in FIFO order, so a busy repository can starve `J`
without any unit being blocked); (F3) a `Named` state is an explanation, not a
promise of progress: a manual pause clears only when an operator lifts it,
and lane-holding block reasons are assumed to wake up
(`SlotCapacity.LaneHoldingReasonsClear`).

A second, smaller property covers the retry that was planned and then dropped:

* `planned_retry_not_rechecked_away`: every classification whose reconciler
  repair is a retry survives `AutoRetryJob#skip_if_failure_no_longer_retryable`
  while the classification is unchanged, and `before_branch_diverged_dropped`
  shows the case that failed before `REPAIRED_BY_RETRY_CLASSIFICATIONS`:
  `branch_diverged` was planned by `BranchDivergedPrOpen` and skipped on every
  attempt, leaving the Job failed with no repair in flight.

Known gap, reported rather than fixed: `needsRebase` without a free rebase slot
is not `Named` from `J`'s side: its queue entry shows no reason while it waits
for a slot (F2). The theorems hold because the slot holders are runnable and
will finish; the UI cannot say so.
-/

namespace SyrusModel
namespace ApprovedProgress

open SlotCapacity (UState runnable active)

structure S where
  /-- `true` once `J`'s landing has been launched. -/
  landing : Bool
  blocker : Bool
  needsRebase : Bool
  own : Option UState
  others : List UState
  lanes : List UState
  deriving DecidableEq, Repr

/-- `CONCURRENT_REBASES_PER_REPO`. -/
def cap : Nat := 3
/-- `landing_concurrency`, clamped to at least 1 by `landing_lane_count`. -/
def laneCount : Nat := 1

def runnableCount (us : List UState) : Nat := (us.filter runnable).length
def activeCount (us : List UState) : Nat := (us.filter active).length

/-- `repo_rebase_concurrency_reached?` after the fix (`RUNNABLE_STATES`). -/
def capReached (s : S) : Bool := decide (cap ≤ runnableCount s.others)
/-- Before the fix (`ACTIVE_STATES`). -/
def capReachedBefore (s : S) : Bool := decide (cap ≤ activeCount s.others)

/-- Lane holders are active by construction (SlotCapacity.lean). -/
def lanesFull (s : S) : Bool := decide (laneCount ≤ s.lanes.length)

def Named (s : S) : Prop :=
  s.blocker = true ∨ s.own.isSome = true ∨ (lanesFull s = true ∧ ∃ u ∈ s.lanes, runnable u = false)

/-- Remove the first runnable entry (a runnable unit finishes). -/
def finishFirst : List UState → Option (List UState)
  | [] => none
  | u :: us => if runnable u then some us else (finishFirst us).map (u :: ·)

/-- The enabled steps, with the cap predicate as a parameter. -/
def next (reached : S → Bool) (s : S) : List S :=
  if s.landing then [] else
  (if !s.blocker && !s.needsRebase && s.own.isNone && !lanesFull s then [{ s with landing := true }] else []) ++
  (if !s.blocker && s.needsRebase && s.own.isNone && !reached s then [{ s with own := some .running }] else []) ++
  (match s.own with
    | some u => if runnable u then [{ s with own := none, needsRebase := false }] else []
    | none => []) ++
  ((finishFirst s.others).map fun os => { s with others := os }).toList ++
  ((finishFirst s.lanes).map fun ls => { s with lanes := ls }).toList

theorem finishFirst_some {us : List UState} (h : ∃ u ∈ us, runnable u = true) : (finishFirst us).isSome = true := by
  induction us with
  | nil => simp at h
  | cons u us ih =>
    unfold finishFirst
    by_cases hu : runnable u = true
    · simp [hu]
    · simp only [hu, Bool.false_eq_true, ite_false, Option.isSome_map]
      obtain ⟨v, hv, hr⟩ := h
      cases List.mem_cons.mp hv with
      | inl he => subst he; exact absurd hr hu
      | inr hm => exact ih ⟨v, hm, hr⟩

theorem exists_runnable_of_count {us : List UState} {k : Nat} (h : k < runnableCount us) :
    ∃ u ∈ us, runnable u = true := by
  unfold runnableCount at h
  cases hl : us.filter runnable with
  | nil => rw [hl] at h; simp at h
  | cons v _ =>
    have hv : v ∈ us.filter runnable := by rw [hl]; exact List.mem_cons_self
    exact ⟨v, (List.mem_filter.mp hv).1, (List.mem_filter.mp hv).2⟩

/-- After the fix: an approved Job that nothing names always has a step. -/
theorem no_silent_stall (s : S) (hl : s.landing = false) (hn : ¬ Named s) : next capReached s ≠ [] := by
  have hb : s.blocker = false := by cases h : s.blocker <;> simp_all [Named]
  have ho : s.own = none := by
    cases h : s.own with
    | none => rfl
    | some _ => exact absurd (Or.inr (Or.inl (by simp [h]))) hn
  unfold next
  simp only [hl, hb, ho, Bool.false_eq_true, ite_false, Bool.not_false, Bool.true_and, Option.isNone_none]
  intro hnil
  simp only [List.append_eq_nil_iff] at hnil
  obtain ⟨⟨⟨⟨h1, h2⟩, _⟩, h4⟩, h5⟩ := hnil
  by_cases hr : s.needsRebase = true
  · by_cases hc : capReached s = true
    · -- the cap is reached by runnable units, so one of them can finish
      have hcount : 0 < runnableCount s.others := by
        have := of_decide_eq_true hc; simp only [cap] at this; omega
      have := finishFirst_some (exists_runnable_of_count hcount)
      cases hf : finishFirst s.others with
      | none => rw [hf] at this; cases this
      | some _ => rw [hf] at h4; simp at h4
    · simp [hr, hc] at h2
  · by_cases hf : lanesFull s = true
    · -- every lane holder is runnable (nothing is named), so one can finish
      have hne : s.lanes ≠ [] := by
        intro he; simp [lanesFull, he, laneCount] at hf
      have hall : ∀ u ∈ s.lanes, runnable u = true := by
        intro u hu
        cases hru : runnable u
        · exact absurd (Or.inr (Or.inr ⟨hf, u, hu, hru⟩)) hn
        · rfl
      obtain ⟨u, us, hu⟩ := List.exists_cons_of_ne_nil hne
      have hmem : u ∈ s.lanes := by rw [hu]; exact List.mem_cons_self
      have := finishFirst_some ⟨u, hmem, hall u hmem⟩
      cases hff : finishFirst s.lanes with
      | none => rw [hff] at this; cases this
      | some _ => rw [hff] at h5; simp at h5
    · simp at hr hf; simp [hr, hf] at h1

/-- The incident: three paused rebases of other Jobs, `J`'s PR needs a rebase,
    and its entry has no blocker. Under the old count nothing can happen and
    nothing says why; under the fix `J`'s rebase is dispatched. -/
theorem before_silent_stall :
    let s : S := { landing := false, blocker := false, needsRebase := true, own := none,
                   others := [.blocked, .blocked, .blocked], lanes := [] }
    next capReachedBefore s = [] ∧ ¬ Named s ∧ next capReached s = [{ s with own := some .running }] := by
  refine ⟨by decide, ?_, by decide⟩
  simp [Named, lanesFull, laneCount]

/-- The ranking function. -/
def rank (s : S) : Nat :=
  if s.landing then 0 else
  1 + runnableCount s.others + runnableCount s.lanes +
    (if s.needsRebase then (if s.own.isNone then 2 else 1) else 0) +
    (match s.own with | some u => if runnable u && !s.needsRebase then 1 else 0 | none => 0)

theorem finishFirst_count : ∀ {us vs : List UState}, finishFirst us = some vs → runnableCount vs < runnableCount us
  | [], _, h => by simp [finishFirst] at h
  | u :: us, vs, h => by
    unfold finishFirst at h
    by_cases hu : runnable u = true
    · simp only [hu, ite_true, Option.some.injEq] at h; subst h
      simp [runnableCount, hu]
    · simp only [hu, Bool.false_eq_true, ite_false, Option.map_eq_some_iff] at h
      obtain ⟨ws, hws, he⟩ := h; subst he
      have := finishFirst_count hws
      simp [runnableCount, hu] at this ⊢; omega

theorem step_decreases (reached : S → Bool) (s t : S) (h : t ∈ next reached s) : rank t < rank s := by
  unfold next at h
  by_cases hl : s.landing = true
  · simp [hl] at h
  · simp only [hl, Bool.false_eq_true, ite_false, List.mem_append] at h
    have hl' : s.landing = false := by simpa using hl
    rcases h with ((((h | h) | h) | h) | h)
    · split at h <;> simp at h; subst h; simp only [rank, hl', ite_true, Bool.false_eq_true, ite_false]; omega
    · split at h <;> simp at h
      rename_i hc; subst h
      simp only [Bool.and_eq_true, Bool.not_eq_true', Option.isNone_iff_eq_none] at hc
      simp [rank, hl', hc.1.2, hc.1.1.2, runnable]
    · cases ho : s.own with
      | none => simp [ho] at h
      | some u =>
        simp only [ho] at h
        split at h <;> simp at h
        rename_i hu; subst h
        cases hr : s.needsRebase <;> simp [rank, hl', ho, hu, hr]
    · cases hf : finishFirst s.others with
      | none => simp [hf] at h
      | some os =>
        simp [hf] at h; subst h
        have := finishFirst_count hf
        simp only [rank, hl', Bool.false_eq_true, ite_false]; omega
    · cases hf : finishFirst s.lanes with
      | none => simp [hf] at h
      | some ls =>
        simp [hf] at h; subst h
        have := finishFirst_count hf
        simp only [rank, hl', Bool.false_eq_true, ite_false]; omega

/-- A run of steps under the fixed cap. -/
inductive Path : S → S → Nat → Prop
  | done (s : S) : Path s s 0
  | step {s t u : S} {n : Nat} : t ∈ next capReached s → Path t u n → Path s u (n + 1)

theorem path_length_le_rank {s u : S} {n : Nat} (p : Path s u n) : n + rank u ≤ rank s := by
  induction p with
  | done => omega
  | step h _ ih => have := step_decreases capReached _ _ h; omega

/-- Liveness: every run is at most `rank s` steps long, and a run that cannot be
    extended ends with `J` landing or `Named`. -/
theorem eventually_lands_or_named {s u : S} {n : Nat} (p : Path s u n) (hmax : next capReached u = []) :
    n ≤ rank s ∧ (u.landing = true ∨ Named u) := by
  refine ⟨by have := path_length_le_rank p; omega, ?_⟩
  by_cases hl : u.landing = true
  · exact Or.inl hl
  · by_cases hn : Named u
    · exact Or.inr hn
    · exact absurd hmax (no_silent_stall u (by simpa using hl) hn)

/-! ## A planned retry is not rechecked away -/

/-- What `RunFailureClassifier` says about a classification. -/
structure Cls where
  retryable : Bool
  /-- `PROVIDER_DELAYED_CLASSIFICATIONS`. -/
  delayed : Bool
  /-- `REPAIRED_BY_RETRY_CLASSIFICATIONS`: the reconciler's repair for it is a
      retry (`BranchDivergedPrOpen`). -/
  repairedByRetry : Bool
  deriving DecidableEq, Repr

/-- The reconciler plans an `AutoRetryAttempt` for it. -/
def plannerRetries (c : Cls) : Bool := c.retryable || c.delayed || c.repairedByRetry

/-- `AutoRetryJob#skip_if_failure_no_longer_retryable` (for a non-preserved
    attempt): skip when the fresh verdict is not retryable. -/
def recheckSkips (attempt fresh : Cls) : Bool :=
  !fresh.retryable && !fresh.delayed && !(fresh.repairedByRetry && fresh == attempt)

/-- Before `REPAIRED_BY_RETRY_CLASSIFICATIONS`. -/
def recheckSkipsBefore (_attempt fresh : Cls) : Bool := !fresh.retryable && !fresh.delayed

theorem planned_retry_not_rechecked_away (c : Cls) (h : plannerRetries c = true) : recheckSkips c c = false := by
  cases c with
  | mk r d b => cases r <;> cases d <;> cases b <;> simp_all [plannerRetries, recheckSkips]

theorem before_branch_diverged_dropped :
    let branchDiverged : Cls := { retryable := false, delayed := false, repairedByRetry := true }
    plannerRetries branchDiverged = true ∧ recheckSkipsBefore branchDiverged branchDiverged = true := by
  decide

end ApprovedProgress
end SyrusModel
