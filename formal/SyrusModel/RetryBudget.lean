/-!
# DOC-44 Phase 3: retry budgets across retry paths

Two paths create `AutoRetryAttempt`s for an ordinary failed Run:

* the reconciler's retry repair (`WorkEngine::RepairExecutor`) numbers an
  attempt by `budget_scope_for(job, provider, classification).count + 1` --
  every attempt of that Job with that provider and classification -- and
  refuses past `MAX_ATTEMPTS`;
* the in-place step retry (`Runs::LifecyclePropagation#
  scheduled_in_place_step_retry?`, for `worker_died` and
  `git_transport_transient` on deterministic Steps) numbers it by the same
  scope restricted to *this Step's* Runs, or the Step's prior failures of that
  classification, whichever is larger.

DOC-44: "Retry budgets cannot be bypassed by switching retry paths."

Proved here:

* `reconciler_respects_in_place`: in-place attempts count against the
  reconciler's job-wide budget, so a Step that used its in-place retries
  cannot get more from the reconciler (`job_bound`);
* `in_place_per_step` (counterexample to a job-wide bound): the in-place
  path gives every Step its own budget, so one Job can run `limit` retries of
  the same classification on each of its Steps -- above the job-wide limit
  the reconciler enforces -- while each Step stays bounded (`step_bound`).
  With a fan-out of many graders that is `limit × graders` retries of one
  outage. Whether that is intended is NY11.

The model is a history: the Step of every attempt already made for one
(job, provider, classification).
-/

namespace SyrusModel
namespace RetryBudget

/-- The reconciler's next attempt number. -/
def jobNumber (history : List Nat) : Nat := history.length + 1

/-- The in-place path's next attempt number for `step` (ignoring the
    prior-failure count, which only raises it). -/
def stepNumber (history : List Nat) (step : Nat) : Nat := (history.filter (· == step)).length + 1

def reconcilerAllows (limit : Nat) (history : List Nat) : Bool := jobNumber history ≤ limit
def inPlaceAllows (limit : Nat) (history : List Nat) (step : Nat) : Bool := stepNumber history step ≤ limit

/-- Every attempt counts against the job-wide number, whichever path made it. -/
theorem reconciler_respects_in_place (history : List Nat) (step : Nat) :
    stepNumber history step ≤ jobNumber history := by
  unfold stepNumber jobNumber
  exact Nat.succ_le_succ (List.length_filter_le _ _)

/-- So once a Step's in-place budget is gone, the reconciler refuses too. -/
theorem job_bound (limit : Nat) (history : List Nat) (step : Nat)
    (h : inPlaceAllows limit history step = false) : reconcilerAllows limit history = false := by
  simp only [inPlaceAllows, reconcilerAllows, decide_eq_false_iff_not, Nat.not_le] at h ⊢
  exact Nat.lt_of_lt_of_le h (reconciler_respects_in_place history step)

/-- Each attempt the in-place path allows is within the Step's budget. -/
theorem step_bound (limit : Nat) (history : List Nat) (step : Nat)
    (h : inPlaceAllows limit history step = true) : (history.filter (· == step)).length < limit := by
  have h' := of_decide_eq_true h
  unfold stepNumber at h'
  omega

/-- Three Steps that each used the limit of 3 have taken 9 retries of one
    classification, and a fourth Step may still retry in place, while the
    reconciler's job-wide budget was spent after the third. -/
theorem in_place_per_step :
    let history := [1, 1, 1, 2, 2, 2, 3, 3, 3]
    inPlaceAllows 3 history 4 = true ∧ reconcilerAllows 3 history = false := by decide

end RetryBudget
end SyrusModel
