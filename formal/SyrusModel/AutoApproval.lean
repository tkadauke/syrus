/-!
# Auto-approval never approves a Job that has no pull request

`AutoApprovalRule#approve_after_grader_success!` runs when a `grader_collect`
Step succeeds. In the initial Workflow the grade loop runs *before*
`summarize`, `test_plan` and `pr_open`, so the Job was marked implemented and
approved while it had no PR. If `pr_open` then failed, the Workflow's failure
propagation skipped the already-approved Job: approved, no PR, no work — the
landing queue blocks it as `missing_pull_request` forever.

Fix: auto-approve only once the Job has a PR; also evaluate the rule when the
Workflow succeeds (after `pr_open`), so nothing that passed its graders loses
its approval.
-/

namespace SyrusModel
namespace AutoApproval

inductive J where | running | implemented | approved | failed deriving DecidableEq, Repr

structure S where
  job : J
  pr : Bool
  gradersPassed : Bool
  /-- The initial Workflow is still active. -/
  active : Bool
  deriving DecidableEq, Repr

inductive Op where | graderSuccess | prOpen | prOpenFails | workflowSucceeds deriving DecidableEq, Repr

def approveOld (s : S) : S :=
  if s.job = .running ∨ s.job = .implemented then { s with job := .approved } else s

/-- The rule after the fix: only with a PR. -/
def approveNew (s : S) : S :=
  if s.pr ∧ (s.job = .running ∨ s.job = .implemented) then { s with job := .approved } else s

def stepOld (s : S) : Op → S
  | .graderSuccess => if s.active then approveOld { s with gradersPassed := true } else s
  | .prOpen => if s.active then { s with pr := true } else s
  | .prOpenFails => if s.active ∧ ¬ s.pr then
      -- JobLifecyclePropagation#fail! skips implemented/approved/landing/closed Jobs
      { s with active := false, job := if s.job = .running then .failed else s.job } else s
  | .workflowSucceeds => if s.active ∧ s.pr then
      { s with active := false, job := if s.job = .running then .implemented else s.job } else s

def stepNew (s : S) : Op → S
  | .graderSuccess => if s.active then approveNew { s with gradersPassed := true } else s
  | .prOpen => if s.active then { s with pr := true } else s
  | .prOpenFails => if s.active ∧ ¬ s.pr then
      { s with active := false, job := if s.job = .running then .failed else s.job } else s
  | .workflowSucceeds => if s.active ∧ s.pr then
      let t := { s with active := false, job := if s.job = .running then .implemented else s.job }
      if t.gradersPassed then approveNew t else t
    else s

def runWith (f : S → Op → S) (s : S) : List Op → S
  | [] => s
  | o :: os => runWith f (f s o) os

def init : S := ⟨.running, false, false, true⟩

/-- Approved with no PR and nothing left working on it. -/
def stranded (s : S) : Bool := s.job = .approved ∧ ¬ s.pr ∧ ¬ s.active

theorem old_strands : stranded (runWith stepOld init [.graderSuccess, .prOpenFails]) = true := by decide

def ops : List Op := [.graderSuccess, .prOpen, .prOpenFails, .workflowSucceeds]

def seqs : Nat → List (List Op)
  | 0 => [[]]
  | n + 1 => (seqs n) ++ ((seqs n).filter (·.length = n)).flatMap fun l => ops.map (· :: l)

/-- Every operation sequence of length up to 6: approved implies a PR. -/
theorem new_approved_has_pr :
    (seqs 6).all (fun os => let s := runWith stepNew init os; s.job ≠ .approved ∨ s.pr) = true := by
  native_decide

/-- And approval is not lost: graders passed, PR opened, Workflow succeeded ⇒ approved. -/
theorem new_still_approves :
    (runWith stepNew init [.graderSuccess, .prOpen, .workflowSucceeds]).job = .approved := by decide

end AutoApproval
end SyrusModel
