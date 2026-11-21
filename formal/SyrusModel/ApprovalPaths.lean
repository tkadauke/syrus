/-!
# Every approval path honours approval-blocking work

A Job can be approved through several doors: the operator's approve endpoint,
the `approve_job` MCP tool, a confirmed pending action, an auto-approval rule,
and a GitHub review the PR poll picks up (`Job#record_github_review_approval!`).
The first three refuse while the Job has approval-blocking runtime work
(`Job#approval_blocking_runtime_work?`: an active Run or WorkUnit whose trigger
kind is not in `NON_APPROVAL_BLOCKING_VALUES`). Approving then would approve a
HEAD the running Workflow is about to move, and moving the Job off `running`
is the running Workflow's own success propagation's call.

The GitHub path, before the fix, did two things first and checked only for an
active *feedback* Workflow afterwards:

1. `mark_implemented! if may_mark_implemented?`: a `running` Job became
   `implemented` while its Workflow was still running. This happened even when
   the approval was then declined, and it is one more producer of the
   `implemented`-under-a-running-Workflow drift the Job-state reconciler keeps
   correcting.
2. It approved under any non-feedback approval-blocking Workflow (`ci_failure`,
   `retry`, `initial`, …).

**Invariant `NoApprovalUnderBlockingWork`:** no approval path changes the Job's
state while approval-blocking work is active. Before the fix the GitHub path
violates it (`github_before_violates`); after it, every path satisfies it
(`github_after_holds`, `all_paths_hold`). Each poll re-reads the PR's reviews,
so a declined GitHub approval is recorded on the first poll after the work
ends (`github_after_eventually_approves`).
-/

namespace SyrusModel
namespace ApprovalPaths

inductive JS where
  | queued | running | implemented | approved
  deriving DecidableEq, Repr

structure Job where
  state : JS
  /-- `approval_blocking_runtime_work?`. -/
  blocking : Bool
  /-- `active_feedback_workflow?`. Every feedback kind blocks approval. -/
  feedback : Bool
  deriving DecidableEq, Repr

/-- Feedback Workflows are approval-blocking (no feedback kind is listed in
    `NON_APPROVAL_BLOCKING_VALUES`). -/
def WellFormed (j : Job) : Prop := j.feedback = true → j.blocking = true

instance (j : Job) : Decidable (WellFormed j) := by unfold WellFormed; infer_instance

/-- `mark_implemented!` from `queued`/`running`. -/
def markImplemented (s : JS) : JS :=
  match s with
  | .queued | .running => .implemented
  | s => s

/-- `approve!` (from `implemented` only). -/
def approve (s : JS) : JS := if s = .implemented then .approved else s

/-- The operator, MCP and pending-action paths. -/
def operatorApprove (j : Job) : Job :=
  if j.blocking then j else { j with state := approve j.state }

/-- `record_github_review_approval!` before the fix. -/
def githubBefore (j : Job) : Job :=
  let s := markImplemented j.state
  if j.feedback then { j with state := s } else { j with state := approve s }

/-- After the fix: refuse while approval-blocking work is active, before
    touching the state. -/
def githubAfter (j : Job) : Job :=
  if j.blocking then j else { j with state := approve (markImplemented j.state) }

def NoApprovalUnderBlockingWork (path : Job → Job) : Prop :=
  ∀ j, WellFormed j → j.blocking = true → (path j).state = j.state

/-- Counterexample: a `running` Job under a non-feedback approval-blocking
    Workflow (e.g. `ci_failure`) is approved by a polled GitHub review. -/
theorem github_before_violates : ¬ NoApprovalUnderBlockingWork githubBefore := by
  intro h
  have := h { state := .running, blocking := true, feedback := false } (by decide) rfl
  simp [githubBefore, markImplemented, approve] at this

/-- Even a *declined* GitHub approval (feedback Workflow running) moved the
    running Job to `implemented`. -/
theorem github_before_drifts_under_feedback :
    (githubBefore { state := .running, blocking := true, feedback := true }).state = .implemented := rfl

theorem operator_holds : NoApprovalUnderBlockingWork operatorApprove := by
  intro j _ hb; simp [operatorApprove, hb]

theorem github_after_holds : NoApprovalUnderBlockingWork githubAfter := by
  intro j _ hb; simp [githubAfter, hb]

theorem all_paths_hold :
    ∀ p ∈ [operatorApprove, githubAfter], NoApprovalUnderBlockingWork p := by
  intro p hp
  simp only [List.mem_cons, List.not_mem_nil, or_false] at hp
  rcases hp with rfl | rfl
  · exact operator_holds
  · exact github_after_holds

/-- Once the work has ended, the next poll approves exactly as before. -/
theorem github_after_eventually_approves (j : Job) (hb : j.blocking = false) :
    githubAfter j = { j with state := approve (markImplemented j.state) } := by
  simp [githubAfter, hb]

/-- Without blocking work the fix changes nothing on any Job. -/
theorem github_after_agrees_when_idle (j : Job) (hb : j.blocking = false) (hf : j.feedback = false) :
    githubAfter j = githubBefore j := by
  simp [githubAfter, githubBefore, hb, hf]

end ApprovalPaths
end SyrusModel
