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

end Examples
end Kernel
end SyrusModel
