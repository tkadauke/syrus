/-!
# A reopened Step waiting for its Run is always someone's to repair (Lead L13)

A retry or a provider backoff reopens a Step that keeps its earlier attempt's
terminal Runs. Until its fresh Run is created, the Step is queued, no Run is
active, and every Run it has is terminal. Two reconciler checks look at queued
Steps in a running Workflow:

* `queued_step_without_run` (repair `resume_queued_step`): a ready Step with no
  Run. Before Lead L13 it required no Runs at all.
* `running_step_with_terminal_runs` (repair `reconcile_step_from_terminal_run`):
  a Step whose Runs are all terminal. Main's `98d30fa654` made it skip a Step
  reopened since its latest Run, which is a retry waiting its turn.

So a reopened Step whose resume never came was skipped by both. The fix counts
"no Run" as "no Run since the reopen" (`Reconciler.reopened_awaiting_run_at`),
in the classifier and in `ResumeQueuedStep`'s re-check alike.

This file proves, over every combination of the inputs both checks read:

1. `before_strands`: before the fix, a ready, reopened Step with old Runs and
   nothing holding it was flagged by neither check.
2. `after_live`: after the fix, every queued Step with no active Run that is
   ready and not deliberately held is flagged by at least one check.
3. `after_exclusive`: no Step is flagged by both, so the two repairs never
   compete for one Step.
4. `resume_agrees`: the resume repair acts on exactly the Steps the classifier
   flags for it (the executor re-checks with the same predicate).
-/

namespace SyrusModel
namespace ReopenedStepLiveness

/-- What both checks read about a queued Step in a running Workflow with no
active Run. -/
structure QueuedStep where
  hasRuns : Bool          -- it has (terminal) Runs from an earlier attempt
  reopenedSince : Bool    -- it or its Workflow was reopened after the latest one ended
  graceElapsed : Bool     -- the grace since creation, or since the reopen, has passed
  handoffReady : Bool     -- `deferred_phase_handoff_ready?`
  held : Bool             -- a deliberate wait, grader admission or a pending backoff
  deriving DecidableEq, Repr

def all : List QueuedStep := Id.run do
  let bools := [true, false]
  let mut out := []
  for a in bools do
    for b in bools do
      for c in bools do
        for d in bools do
          for e in bools do
            out := out ++ [⟨a, b, c, d, e⟩]
  return out

/-- `queued_step_without_run` before the fix. -/
def withoutRunBefore (s : QueuedStep) : Bool :=
  !s.hasRuns && s.graceElapsed && s.handoffReady && !s.held

/-- After the fix: a Step with Runs counts when it was reopened since them. -/
def withoutRunAfter (s : QueuedStep) : Bool :=
  (!s.hasRuns || s.reopenedSince) && s.graceElapsed && s.handoffReady && !s.held

/-- `running_step_with_terminal_runs` since main's `98d30fa654`. -/
def terminalRuns (s : QueuedStep) : Bool :=
  s.hasRuns && !s.reopenedSince

/-- A Step the reconciler should act on: ready, and nothing holds it on purpose.
A Step with old Runs that was not reopened is stuck however ready it is. -/
def actionable (s : QueuedStep) : Bool :=
  (s.graceElapsed && s.handoffReady && !s.held) || (s.hasRuns && !s.reopenedSince)

def flaggedBefore (s : QueuedStep) : Bool := withoutRunBefore s || terminalRuns s
def flaggedAfter (s : QueuedStep) : Bool := withoutRunAfter s || terminalRuns s

/-- The stranded Step: reopened for a retry, ready, nothing holding it. -/
def stranded : QueuedStep := ⟨true, true, true, true, false⟩

theorem before_strands : actionable stranded = true ∧ flaggedBefore stranded = false := by decide

theorem after_live : all.all (fun s => !actionable s || flaggedAfter s) = true := by decide

theorem after_exclusive : all.all (fun s => !(withoutRunAfter s && terminalRuns s)) = true := by decide

/-- `ResumeQueuedStep#perform` re-checks the Step before resuming it: queued,
no Run (or reopened since its Runs), handoff ready. The deliberate holds are
re-evaluated by `DeferredPhaseResume` itself, so they are not part of this
re-check; the grace only delays detection. -/
def resumeActs (s : QueuedStep) : Bool := (!s.hasRuns || s.reopenedSince) && s.handoffReady

theorem resume_agrees : all.all (fun s => !withoutRunAfter s || resumeActs s) = true := by decide

/-- Before the fix the executor refused every Step with Runs, so even a Step the
classifier had flagged by another route could not be resumed. -/
def resumeActsBefore (s : QueuedStep) : Bool := !s.hasRuns && s.handoffReady

theorem resume_before_refuses_stranded : resumeActsBefore stranded = false := by decide

end ReopenedStepLiveness
end SyrusModel
