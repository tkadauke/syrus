/-!
# DOC-44 Phase 1 kernel: dependencies and satisfaction modes

`JobDependency` (`app/models/job_dependency.rb` and
`job_dependency/satisfaction_modes/*.rb`) for Job targets. A dependency is in
one of three positions for its dependent:

* **satisfied** for execution (`execution_dependency_satisfied?`): the
  dependent may start;
* **terminally unsuccessful** (`dependency_terminal_unsuccessful_for_execution?`):
  it never will be satisfied, and the dependent's start fails closed;
* otherwise **waiting**.

Closure reasons are abstracted into the classes the modes distinguish:
`landed` (pr_merged, external_pr_merged, promotion_landed, hotfix_sync_landed,
emergency_landed), `approvedClose` (pr_approved), `noChanges`,
`investigationReported`, and `other` (any unsuccessful reason).

**Invariants.**
* `never_both`: no dependency is both satisfied and terminally unsuccessful.
* `closed_decided` (after the fix): once the upstream Job is closed, every mode
  is decided, either satisfied or terminally unsuccessful. A dependent never
  waits on a Job that can no longer change.

**Counterexample (before the fix).** `execution_dependency_satisfied?`
refused whenever the upstream approval was withdrawn, unless the mode was
`closed`, even after the dependency had succeeded. Only approving clears
`approval_withdrawn_at`. A withdrawn Job whose PR was then merged on GitHub,
emergency-landed or closed with no changes is succeeded and still withdrawn.
Its dependents were neither satisfied nor terminally failed, so they waited
forever (`closed_undecided_before`).
-/

namespace SyrusModel
namespace Kernel
namespace Deps

inductive Closure where
  | landed | approvedClose | noChanges | investigationReported | other
  deriving DecidableEq, Repr

/-- `Job::SUCCESSFUL_CLOSURE_REASONS` -/
def Closure.successful : Closure → Bool
  | .other => false
  | _ => true

inductive Open where
  | implemented | approved | landing | elsewhere
  deriving DecidableEq, Repr

/-- The upstream Job as the modes see it. -/
structure JobView where
  closed : Option Closure
  openState : Open
  /-- PR number, branch and head SHA all present. -/
  prReady : Bool
  landedSha : Bool
  approvalWithdrawn : Bool
  sameEpic : Bool
  stageReached : Bool
  deriving DecidableEq, Repr

inductive Mode where
  | success | landed | closed | deploymentStage
  deriving DecidableEq, Repr

def JobView.isClosed (j : JobView) : Bool := j.closed.isSome

/-- `Job#dependency_succeeded?` -/
def JobView.succeeded (j : JobView) : Bool :=
  match j.closed with
  | some c => c.successful
  | none => false

def sameEpicApproved (j : JobView) : Bool :=
  j.sameEpic && j.closed.isNone && (j.openState == .approved || j.openState == .landing)

/-- `dependency_succeeded?` per mode. -/
def succeeded : Mode → JobView → Bool
  | .success, j => j.succeeded || sameEpicApproved j
  | .landed, j => match j.closed with
    | some .noChanges => true
    | some .landed => j.landedSha
    | _ => false
  | .closed, j => j.isClosed
  | .deploymentStage, j => j.stageReached

def readyForExecution (j : JobView) : Bool :=
  j.closed.isNone && j.openState == .implemented && j.prReady

/-- `dependency_approval_withdrawn_for_execution?` -/
def withdrawn (j : JobView) : Bool := j.approvalWithdrawn && !sameEpicApproved j

/-- `execution_dependency_satisfied?` as it was. -/
def satisfiedBefore (m : Mode) (j : JobView) : Bool :=
  if m == .closed then succeeded m j
  else if withdrawn j then false
  else match m with
    | .success => succeeded m j || readyForExecution j
    | _ => succeeded m j

/-- After the fix: a withdrawal only blocks a dependency that has not
    succeeded yet. -/
def satisfiedAfter (m : Mode) (j : JobView) : Bool :=
  if m == .closed then succeeded m j
  else if withdrawn j && !succeeded m j then false
  else match m with
    | .success => succeeded m j || readyForExecution j
    | _ => succeeded m j

/-- `dependency_terminal_unsuccessful_for_execution?` -/
def terminal : Mode → JobView → Bool
  | .landed, j => !succeeded .landed j && j.isClosed &&
      (match j.closed with | some .landed => false | _ => true)
  | .deploymentStage, j => !succeeded .deploymentStage j && j.isClosed && !j.succeeded
  | m, j => !succeeded m j && j.isClosed

def bools : List Bool := [false, true]

def allJobs : List JobView :=
  [none, some Closure.landed, some .approvedClose, some .noChanges, some .investigationReported, some .other].flatMap fun closed =>
  [Open.implemented, .approved, .landing, .elsewhere].flatMap fun openState =>
  bools.flatMap fun prReady => bools.flatMap fun landedSha => bools.flatMap fun approvalWithdrawn =>
  bools.flatMap fun sameEpic => bools.map fun stageReached =>
    { closed, openState, prReady, landedSha, approvalWithdrawn, sameEpic, stageReached }

def allModes : List Mode := [.success, .landed, .closed, .deploymentStage]

/-- Counterexample: a withdrawn Job whose PR was merged on GitHub. -/
def mergedAfterWithdrawal : JobView :=
  { closed := some .landed, openState := .elsewhere, prReady := true, landedSha := true,
    approvalWithdrawn := true, sameEpic := false, stageReached := false }

theorem closed_undecided_before :
    satisfiedBefore .success mergedAfterWithdrawal = false ∧ terminal .success mergedAfterWithdrawal = false := by
  decide

theorem never_both_before :
    allModes.all (fun m => allJobs.all (fun j => !(satisfiedBefore m j && terminal m j))) = true := by
  native_decide

theorem never_both :
    allModes.all (fun m => allJobs.all (fun j => !(satisfiedAfter m j && terminal m j))) = true := by
  native_decide

/-- After the fix every closed upstream Job decides its dependency, except a
    `deployment_stage` dependency on a successfully closed Job that never
    reached the stage, and a `landed` dependency on a Job closed as landed
    without a recorded landed SHA. Both are genuine waits on data, listed so
    the exception is explicit. -/
def closedDecidedException (m : Mode) (j : JobView) : Bool :=
  (m == .deploymentStage && j.succeeded && !j.stageReached) ||
  (m == .landed && j.closed == some .landed && !j.landedSha)

theorem closed_decided :
    allModes.all (fun m => allJobs.all (fun j =>
      !j.isClosed || closedDecidedException m j || satisfiedAfter m j || terminal m j)) = true := by
  native_decide

theorem closed_decided_fails_before :
    ¬ (allModes.all (fun m => allJobs.all (fun j =>
      !j.isClosed || closedDecidedException m j || satisfiedBefore m j || terminal m j)) = true) := by
  native_decide

/-- The fix only ever turns waiting into satisfied: anything satisfied before
    is satisfied after... -/
theorem after_extends_before :
    allModes.all (fun m => allJobs.all (fun j => !satisfiedBefore m j || satisfiedAfter m j)) = true := by
  native_decide

/-- ...and it changes the answer only for a dependency that has already
    succeeded (including a deployment stage reached while the upstream Job is
    still open). -/
theorem after_differs_only_when_succeeded :
    allModes.all (fun m => allJobs.all (fun j => satisfiedBefore m j == satisfiedAfter m j || succeeded m j)) = true := by
  native_decide

end Deps
end Kernel
end SyrusModel
