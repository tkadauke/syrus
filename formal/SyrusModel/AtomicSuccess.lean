/-!
# Recording a successful step: one commit, not two

`RunJob#record_successful_step!` used to commit `run.succeed!` and
`step.succeed!` separately. Between the two commits the database held a Step
that is running while every Run is terminal -- exactly what
`classify_active_steps_with_terminal_runs` flags -- and the Run's own
after-commit propagation ran in that state. In production the reconciler
planned a repair for it on many passes and skipped it ("Step is succeeded, not
active") once the second commit landed.

The model: the committed state is a pair (run, step). A writer is a list of
commits; an observer (another connection, or a commit callback) can read the
committed state after any prefix of them. The abnormal state is observable
exactly when some prefix produces it.
-/

namespace SyrusModel
namespace AtomicSuccess

inductive S where
  | running | succeeded
  deriving DecidableEq, Repr

structure Committed where
  run : S
  step : S
  deriving DecidableEq, Repr

/-- What the reconciler flags: the Step is active and its only Run is terminal. -/
def abnormal (c : Committed) : Bool := c.step = .running && c.run = .succeeded

/-- A commit replaces the committed state. -/
abbrev Commit := Committed → Committed

/-- Every state an observer can read: the start and the state after each prefix. -/
def observable (start : Committed) : List Commit → List Committed
  | [] => [start]
  | c :: cs => start :: observable (c start) cs

def succeedRun : Commit := fun c => { c with run := .succeeded }
def succeedStep : Commit := fun c => { c with step := .succeeded }
def succeedBoth : Commit := fun _ => { run := .succeeded, step := .succeeded }

def start : Committed := { run := .running, step := .running }

/-- Before: two commits. The abnormal state is observable. -/
theorem split_exposes : (observable start [succeedRun, succeedStep]).any abnormal = true := by
  decide

/-- After: one commit. No observer ever sees the abnormal state. -/
theorem atomic_hides : (observable start [succeedBoth]).any abnormal = false := by
  decide

/-- Both writers end in the same state, so nothing but the window changes. -/
theorem same_outcome : succeedStep (succeedRun start) = succeedBoth start := rfl

/-- The commit callbacks see the final state: under the single commit, the Run's
    propagation observes a succeeded Step. -/
theorem callback_sees_step_succeeded : (succeedBoth start).step = .succeeded := rfl

end AtomicSuccess
end SyrusModel
