/-!
# Operator feedback on blocked work never abandons an implemented branch

Derived from a recent main commit ("Rerun feedback, not implementation, when a
feedback workflow is blocked"). Its invariant: feedback delivered to a Job
whose current Workflow is blocked (`cannot_proceed`) starts an implementation
attempt from the base only when the blocked work *was* an implementation
attempt; otherwise it continues on the implemented branch.

`BlockedImplementationFeedback.retry!` decided by "is the blocked Workflow a
feedback kind" (chat or PR feedback). Other kinds that also work on the
implemented branch fell through to the implementation retry. The reachable one
is a blocked CI repair (`ci_failure`): its `analyze_and_fix` agent can report
`cannot_proceed`, and the feedback either started over from the base,
abandoning the PR it was repairing, or was refused while other work was active
(`ci_repair_restarts_from_base`). Landing and non-approval-blocking kinds
(rebases, visual reviews) never reach this path.

The fix classifies by an explicit `Workflow::TriggerKind` field,
`builds_from_base` (`initial`, `retry`, `base_refresh_retry`), rather than by
feedback kind.
-/

namespace SyrusModel
namespace BlockedFeedback

inductive Kind where
  | initial | retry | baseRefreshRetry | chatFeedback | prComment | ciFailure
  deriving DecidableEq, Repr

def Kind.feedback : Kind → Bool
  | .chatFeedback | .prComment => true
  | _ => false

/-- `builds_from_base` -/
def Kind.buildsFromBase : Kind → Bool
  | .initial | .retry | .baseRefreshRetry => true
  | _ => false

/-- Whether the blocked Workflow's work lives on the implemented branch. -/
def Kind.onBranch : Kind → Bool := fun k => !k.buildsFromBase

inductive Action where
  | retryImplementation
  | feedbackOnBranch
  deriving DecidableEq, Repr

def before (k : Kind) (_hasBranch : Bool) : Action :=
  if k.feedback then .feedbackOnBranch else .retryImplementation

def after (k : Kind) (hasBranch : Bool) : Action :=
  if k.feedback then .feedbackOnBranch
  else if k.buildsFromBase then .retryImplementation
  else if hasBranch then .feedbackOnBranch
  else .retryImplementation

theorem ci_repair_restarts_from_base :
    before .ciFailure true = .retryImplementation ∧ Kind.onBranch .ciFailure = true := by decide

/-- After the fix, work that lives on an existing branch is never answered by
    rebuilding from the base. -/
theorem after_keeps_branch (k : Kind) (h : k.onBranch = true) : after k true = .feedbackOnBranch := by
  cases k <;> simp_all [after, Kind.onBranch, Kind.buildsFromBase, Kind.feedback]

/-- A blocked implementation attempt still gets an implementation retry. -/
theorem after_retries_implementation (k : Kind) (hb : k.buildsFromBase = true) (hasBranch : Bool) :
    after k hasBranch = .retryImplementation := by
  cases k <;> simp_all [after, Kind.buildsFromBase, Kind.feedback]

/-- Feedback kinds are decided exactly as before. -/
theorem after_feedback_unchanged (k : Kind) (hasBranch : Bool) (hf : k.feedback = true) :
    after k hasBranch = before k hasBranch := by
  simp [after, before, hf]

end BlockedFeedback
end SyrusModel
