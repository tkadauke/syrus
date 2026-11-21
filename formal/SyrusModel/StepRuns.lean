/-!
# One active Run per Step

Runs are created in two places. `StepDispatcher.create_run_and_enqueue` holds
the Step's row lock and refuses a Step that already has an active Run.
`RetryFailedStepEnqueuer#create_run_for!` reopened a failed Step and created a
Run with no such check. A Step can be failed while its Run is still live (the
reconciler reconciles a Step from its terminal Run records, a worker's Run
outlives its Step's failure), so the retry added a second active Run.

Fix: the retry refuses while the Step has an active Run, and creates its Run
under the Step lock, reusing one the dispatcher already started.
-/

namespace SyrusModel
namespace StepRuns

inductive St where | queued | running | failed deriving DecidableEq, Repr

structure S where
  step : St
  active : Nat
  deriving DecidableEq, Repr

inductive Op where
  | dispatch      -- create_run_and_enqueue
  | retry         -- RetryFailedStepEnqueuer
  | finish        -- a Run finishes
  | failStep      -- the Step is marked failed (its Run may still be live)
  deriving DecidableEq, Repr

def dispatch (s : S) : S := if s.step != .failed && s.active = 0 then { s with step := .running, active := 1 } else s
def finish (s : S) : S := if s.active > 0 then { s with active := s.active - 1 } else s
def failStep (s : S) : S := { s with step := .failed }

def retryOld (s : S) : S := if s.step = .failed then { step := .queued, active := s.active + 1 } else s
def retryNew (s : S) : S := if s.step = .failed && s.active = 0 then { step := .queued, active := 1 } else s

def stepWith (retry : S → S) (s : S) : Op → S
  | .dispatch => dispatch s
  | .retry => retry s
  | .finish => finish s
  | .failStep => failStep s

def runWith (retry : S → S) : List Op → S → S
  | [], s => s
  | o :: os, s => runWith retry os (stepWith retry s o)

def ops : List Op := [.dispatch, .retry, .finish, .failStep]

def seqs : Nat → List (List Op)
  | 0 => [[]]
  | n + 1 => [[]] ++ (seqs n).flatMap fun l => ops.map (· :: l)

def init : S := ⟨.queued, 0⟩

theorem old_two_active : (runWith retryOld [.dispatch, .failStep, .retry] init).active = 2 := by decide

/-- Every interleaving of up to 6 operations keeps at most one active Run. -/
theorem new_at_most_one :
    (seqs 6).all (fun os => (runWith retryNew os init).active ≤ 1) = true := by native_decide

end StepRuns
end SyrusModel
