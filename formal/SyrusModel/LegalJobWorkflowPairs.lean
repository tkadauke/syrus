/-!
# DOC-44 job state: the drift classifier agrees with start propagation

`job-state-vs-active-workflow-kind` needs a declared table of legal pairs of
(Job state, active Workflow kind). Start propagation
(`JobLifecyclePropagation.lifts_job_on_start?`) defines which pairs a healthy
system produces:

- an ordinary Workflow lifts the Job to `running`;
- landing and infrastructure Workflows leave it alone;
- a non-approval-blocking follow-up (rebase, manual reviews, visual diff)
  leaves an *implemented* Job implemented.

The reconciler's `classify_job_workflow_drift` reports active Workflows on a
Job in any state outside {queued, running, landing, coding, approved, closed}.
Its exceptions are a failed Job under repair and an expected start-block.
Before F89 it had no exception for the implemented + non-approval-blocking
pair, so it reported every such rebase as drift.

Over every reachable starting state and every kind category, starting the
Workflow from that state yields a pair. Proved:

- `legal_pairs_not_reported`: no pair that start propagation produces is
  reported as drift;
- `approval_blocking_on_implemented_reported`: an implemented Job with an
  active approval-blocking Workflow, which start propagation would have
  lifted, is still reported;
- the old classifier reports a produced pair (`before_reports_legal_pair`).
-/

namespace SyrusModel
namespace LegalJobWorkflowPairs

inductive JobState where
  | queued
  | running
  | implemented
  | approved
  | landing
  | coding
  | failed
  | triaging
  | backlog
deriving DecidableEq, Repr

inductive Kind where
  | ordinary
  | nonApprovalBlocking
  | landingKind
  | infrastructure
deriving DecidableEq, Repr

open JobState Kind

/-- `lifts_job_on_start?` plus `may_start_running?` (from queued/implemented). -/
def afterStart (s : JobState) (k : Kind) : JobState :=
  let lifts := match k with
    | .landingKind | .infrastructure => false
    | .nonApprovalBlocking => s != implemented
    | .ordinary => true
  if lifts && (s == queued || s == implemented) then running else s

/-- `classify_job_workflow_drift` for a Job whose only active Workflow has kind `k`
(no repair, no expected start block). `fixed` adds the F89 exception. -/
def reportsDrift (fixed : Bool) (s : JobState) (k : Kind) : Bool :=
  if s == queued || s == running || s == landing || s == coding || s == approved then false
  else if fixed && s == implemented && k == nonApprovalBlocking then false
  else true

def states : List JobState := [queued, running, implemented, approved, landing, coding, failed, triaging, backlog]
def kinds : List Kind := [ordinary, nonApprovalBlocking, landingKind, infrastructure]

/-- Starting states from which a Workflow of each kind is launched in practice:
follow-ups and handoffs start on implemented Jobs, initial work on queued ones,
landing on approved ones. -/
def launchedFrom : Kind → List JobState
  | .ordinary => [queued, implemented]
  | .nonApprovalBlocking => [implemented, approved]
  | .landingKind => [approved, landing]
  | .infrastructure => [queued, running]

def check : Bool :=
  kinds.all fun k => (launchedFrom k).all fun s => !reportsDrift true (afterStart s k) k

theorem legal_pairs_not_reported : check = true := by native_decide

theorem approval_blocking_on_implemented_reported : reportsDrift true implemented ordinary = true := by native_decide

theorem before_reports_legal_pair :
    reportsDrift false (afterStart implemented nonApprovalBlocking) nonApprovalBlocking = true := by native_decide

end LegalJobWorkflowPairs
end SyrusModel
