/-!
# Every path that lands a merge-train member cleans it up the same way

Derived from a recent main commit ("Close the PR and branch of a merge-train
member the reconciler lands"). Its invariant: once a member is landed, its PR
is commented on and closed, its stacked child PRs are retargeted onto the
train's base, and its branch is deleted, whichever path landed it.

Three paths land a member:

* `Steps::MergeTrainLand#reconcile_members!` (the happy path);
* the reconciler's member repair (`repair_merge_train_member_reconciliation`),
  fixed by that commit;
* `MergeTrainFailureHandler#complete_landing!`, which self-heals a member the
  failed train had already landed. It closed the PR but neither retargeted
  stacked children nor deleted the branch (`self_heal_incomplete`). The
  stale-branch reaper never deletes a branch an open PR targets, so a stacked
  child kept pointing at the landed member's branch.

Both off-step paths now call `MergeTrainMemberLandedCleanup`, which does the
happy path's cleanup.
-/

namespace SyrusModel
namespace MemberLandingCleanup

inductive Path where | landStep | reconcilerRepair | failureSelfHeal deriving DecidableEq, Repr

inductive Action where | closePr | retargetChildren | deleteBranch deriving DecidableEq, Repr

def allActions : List Action := [.closePr, .retargetChildren, .deleteBranch]

def before : Path → List Action
  | .landStep => allActions
  | .reconcilerRepair => allActions
  | .failureSelfHeal => [.closePr]

/-- `MergeTrainMemberLandedCleanup` for the two off-step paths. -/
def after : Path → List Action
  | .landStep => allActions
  | _ => allActions

theorem self_heal_incomplete : Action.retargetChildren ∉ before .failureSelfHeal := by decide

theorem after_uniform (p : Path) (a : Action) : a ∈ after p := by
  cases p <;> cases a <;> decide

end MemberLandingCleanup
end SyrusModel
