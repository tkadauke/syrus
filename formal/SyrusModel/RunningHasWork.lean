/-!
# DOC-44 job state: a running Job always has work behind it

"A Job is running or landing but no Workflow is working on it" must be
unreachable. Here is how a Workflow decides its Job's state:

- **Start.** `JobLifecyclePropagation.lifts_job_on_start?` moves the Job to
  `running` for every kind except landing and infrastructure ones (and
  non-approval-blocking follow-ups on an implemented Job).
- **End.** When the Workflow ends, someone must move the Job off `running`:
  - generic propagation (`fail!` / `cancel!`);
  - or, for a kind that owns its Job lifecycle, that definition's
    `after_fail` / `after_cancel` hook.

`TriggerKind` registry audit: three owning kinds still lift the Job on start.
They are `coding_handoff`, `local_mode_handoff` and `external_pr_ingest`.
Before F88 two of them could strand it:

- `CodingHandoff.after_fail` returned before failing the Job whenever Coding
  Mode was switched off;
- neither handoff had an `after_cancel`, and generic `cancel!` skips both.

For every category of kind that lifts the Job, each terminal outcome, and the
Coding Mode flag either way:

- `lifted_job_settles`: after the Workflow ends, the Job is no longer
  `running`, unless the end was a supersession, in which case newer work owns
  the Job (`superseded_cancellation?`);
- the old hooks strand the Job (`before_strands`).

Landing and infrastructure kinds never lift the Job, so they are outside this
property. Their own Job states are covered by the landing handlers.
-/

namespace SyrusModel
namespace RunningHasWork

/-- Kinds that lift the Job on start, by who settles it at the end. -/
inductive Owner where
  | generic -- JobLifecyclePropagation.fail!/cancel!
  | codingHandoff
  | localModeHandoff
  | externalPrIngest
deriving DecidableEq, Repr

inductive Outcome where
  | failed
  | cancelled (superseded : Bool)
deriving DecidableEq, Repr

/-- Job state after the Workflow ends: `true` = still running. -/
def stillRunning (fixed : Bool) (codingModeOn : Bool) : Owner → Outcome → Bool
  -- generic: fail! fails a running Job; cancel! fails it unless superseded
  | .generic, .failed => false
  | .generic, .cancelled sup => sup
  -- external_pr_ingest: after_fail settles (implemented or failed); generic cancel! applies
  | .externalPrIngest, .failed => false
  | .externalPrIngest, .cancelled sup => sup
  -- coding handoff
  | .codingHandoff, .failed => !fixed && !codingModeOn
  | .codingHandoff, .cancelled sup => if fixed then sup else true
  -- local-mode handoff
  | .localModeHandoff, .failed => false
  | .localModeHandoff, .cancelled sup => if fixed then sup else true

def owners : List Owner := [.generic, .codingHandoff, .localModeHandoff, .externalPrIngest]
def outcomes : List Outcome := [.failed, .cancelled false, .cancelled true]

def superseded : Outcome → Bool
  | .cancelled true => true
  | _ => false

def check : Bool :=
  owners.all fun o => outcomes.all fun out => [false, true].all fun flag =>
    !stillRunning true flag o out || superseded out

theorem lifted_job_settles : check = true := by native_decide

theorem before_strands :
    stillRunning false false .codingHandoff .failed &&
    stillRunning false true .codingHandoff (.cancelled false) &&
    stillRunning false true .localModeHandoff (.cancelled false) = true := by native_decide

end RunningHasWork
end SyrusModel
