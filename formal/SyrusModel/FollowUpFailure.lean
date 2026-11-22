/-!
# DOC-44 job state: a failed follow-up never regresses a Job with a PR

"Feedback and repair Workflows on an existing Job never regress its state."
This is `Workflows::JobLifecyclePropagation.fail!`, branch for branch.

A follow-up that is approval-blocking (`ci_failure`, `pr_comment`, ...) lifts
an implemented Job to `running` when it starts. When it fails, `fail!` decides
the Job's state. Before F87, a failure whose last Run produced no changes
closed the Job as `no_changes`, unless the CI-not-reproduced diversion applied.
That diversion only covers `ci_failure` with no grader reporting `test_failed`.
So a CI repair that gave up without a diff after a grader had reproduced the
failure closed a Job that still had an open, unmerged PR. The `landed`
dependency mode counts such a closure as landed.

After the fix, the `no_changes` closure applies only to a Job without a PR.

Over every Job state, PR or not, failure kind (no changes or other), CI
diversion (applies or not), and lifecycle ownership:

- `pr_job_never_closed`: a Job with a PR is never closed by a failed Workflow;
- `pr_job_never_before_pr`: it never returns to a pre-PR state (queued,
  triaging, backlog);
- `no_pr_no_changes_still_closes`: a Job without a PR whose attempt produced
  nothing is still closed as `no_changes`, as intended;
- the old rule closes a running Job with a PR (`before_violates`).
-/

namespace SyrusModel
namespace FollowUpFailure

inductive State where
  | queued
  | running
  | implemented
  | approved
  | landing
  | failed
  | closed
  | triaging
  | backlog
deriving DecidableEq, Repr

open State

def states : List State := [queued, running, implemented, approved, landing, failed, closed, triaging, backlog]

structure Input where
  state : State
  hasPR : Bool
  noChanges : Bool
  ciDiversion : Bool -- CiFailureNotReproduced.applies?, which itself requires a PR
  ownsLifecycle : Bool
deriving Repr

/-- `fail!` (and `CiFailureNotReproduced.call`); `fixed` adds the PR guard. -/
def fail (fixed : Bool) (i : Input) : State :=
  if i.ownsLifecycle then i.state
  else if i.noChanges && i.ciDiversion && i.hasPR then
    (if i.state == landing || i.state == closed then i.state
     else if i.state == running then implemented else i.state)
  else if i.state == implemented || i.state == approved || i.state == landing || i.state == closed then i.state
  else if i.noChanges && (!fixed || !i.hasPR) then closed
  else
    -- start_running! if never started while queued, then mark_failed (from running only)
    let s := if i.state == queued then running else i.state
    if s == running then failed else s

def bools : List Bool := [false, true]

def inputs : List Input :=
  states.flatMap fun s => bools.flatMap fun pr => bools.flatMap fun nc => bools.flatMap fun ci =>
    bools.map fun own => { state := s, hasPR := pr, noChanges := nc, ciDiversion := ci, ownsLifecycle := own }

def preIntake : State → Bool
  | queued | triaging | backlog => true
  | _ => false

def check : Bool :=
  inputs.all fun i =>
    let out := fail true i
    (!i.hasPR || i.state == closed || out != closed) &&
    (!i.hasPR || preIntake i.state || !preIntake out)

theorem pr_job_never_closed_and_never_before_pr : check = true := by native_decide

theorem no_pr_no_changes_still_closes :
    fail true { state := running, hasPR := false, noChanges := true, ciDiversion := false, ownsLifecycle := false } = closed := by
  native_decide

theorem before_violates :
    fail false { state := running, hasPR := true, noChanges := true, ciDiversion := false, ownsLifecycle := false } = closed := by
  native_decide

end FollowUpFailure
end SyrusModel
