import SyrusModel.Kernel.Reconcile

/-!
# Kernel examples: the first canonical fixtures

Small worlds whose diagnosis is checked by `decide`. They double as the first
fixtures for the executable oracle and the Ruby conformance phase (DOC-44
Phase 2).
-/

namespace SyrusModel
namespace Kernel
namespace Examples

open World

/-- A failed Workflow whose cleanup was lost: one Step and one Run still
    running, its unit still running, and the unit's Job lock still held. -/
def lostCleanup : World where
  intents := [⟨1, .requested⟩]
  units := [⟨10, 1, some 100, .running⟩]
  workflows := [⟨100, .failed⟩]
  steps := [⟨1000, 100, .running⟩]
  runs := [⟨5000, 1000, .running⟩]
  locks := [⟨"job:7", 10⟩]

example : lostCleanup.diagnose =
    [ .activeRunUnderTerminalWorkflow 5000,
      .activeStepUnderTerminalWorkflow 1000,
      .activeUnitBehindTerminalWorkflow 10 .failed,
      .lockOfInactiveUnit "job:7" ] := by decide

example : lostCleanup.reconcile =
    { lostCleanup with
      units := [⟨10, 1, some 100, .failed⟩]
      steps := [⟨1000, 100, .cancelled⟩]
      runs := [⟨5000, 1000, .cancelled⟩]
      locks := [] } := by decide

/-- A blocked Workflow: terminal for the Workflow machine, but its unit stays
    active and keeps its lock (DOC-44). Only the leftover Run is cleaned up. -/
def blockedWorkflow : World where
  intents := [⟨1, .requested⟩]
  units := [⟨10, 1, some 100, .blocked⟩]
  workflows := [⟨100, .blocked⟩]
  steps := [⟨1000, 100, .blocked⟩]
  runs := [⟨5000, 1000, .queued⟩]
  locks := [⟨"job:7", 10⟩]

example : blockedWorkflow.diagnose = [ .activeRunUnderTerminalWorkflow 5000 ] := by decide

/-- A healthy running Workflow has nothing to repair. -/
def healthy : World where
  intents := [⟨1, .requested⟩]
  units := [⟨10, 1, some 100, .running⟩]
  workflows := [⟨100, .running⟩]
  steps := [⟨1000, 100, .running⟩]
  runs := [⟨5000, 1000, .running⟩]
  locks := [⟨"job:7", 10⟩]

example : healthy.diagnose = [] := by decide

/-- A failed Workflow keeps its queued tail for a retry from the failed Step
    (decision NY4); only the running Step is cleaned up. Phase 2 conformance
    caught the first kernel cancelling the tail
    (`codex_overload_initial_retries`). -/
def failedWithQueuedTail : World where
  intents := [⟨1, .failed⟩]
  units := [⟨10, 1, some 100, .failed⟩]
  workflows := [⟨100, .failed⟩]
  steps := [⟨1000, 100, .failed⟩, ⟨1001, 100, .running⟩, ⟨1002, 100, .queued⟩]
  runs := [⟨5000, 1000, .failed⟩]

example : failedWithQueuedTail.diagnose = [ .activeStepUnderTerminalWorkflow 1001 ] := by decide

/-- A live Workflow with an active Run left on a Step that has already
    finished: the Run is obsolete and skipped, and nothing else changes.
    Phase 2 differential testing found the first kernel missing this rule. -/
def activeRunOnFinishedStep : World where
  intents := [⟨1, .requested⟩]
  units := [⟨10, 1, some 100, .running⟩]
  workflows := [⟨100, .running⟩]
  steps := [⟨1000, 100, .skipped⟩, ⟨1001, 100, .running⟩]
  runs := [⟨5000, 1000, .queued⟩, ⟨5001, 1001, .running⟩]
  locks := [⟨"job:7", 10⟩]

example : activeRunOnFinishedStep.diagnose = [ .activeRunOnTerminalStep 5000 ] := by decide

example : activeRunOnFinishedStep.reconcile =
    { activeRunOnFinishedStep with runs := [⟨5000, 1000, .skipped⟩, ⟨5001, 1001, .running⟩] } := by decide

end Examples
end Kernel
end SyrusModel
