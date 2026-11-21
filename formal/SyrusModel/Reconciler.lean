import SyrusModel.WorkUnits

/-!
# Reconciler: WorkUnit / WorkIntent classifiers and repairs

Classifiers mirror `WorkEngine::Reconciler#classify_*` for the ownership layer;
repairs mirror the matching `WorkEngine::RepairExecutor::Policies::*#perform`,
which re-check their guards against fresh database state rather than the
classification snapshot. Each repair below therefore takes the *current*
world and re-evaluates its own guard.
-/

namespace SyrusModel
namespace World

variable {nI nU nK : Nat} (w : World nI nU nK)

def holdsAny (u : Fin nU) : Prop := ∃ k, w.holder k = some u
instance (u : Fin nU) : Decidable (w.holdsAny u) := by unfold holdsAny; infer_instance

/-! ## Classifiers -/

/-- `classify_terminal_work_units_with_active_locks` -/
def terminalWithLocks (u : Fin nU) : Prop :=
  (w.unit u).state.terminal = true ∧ w.holdsAny u

/-- `classify_active_work_units_without_workflows` (closed-Job exemption not modelled) -/
def activeWithoutWorkflow (u : Fin nU) : Prop :=
  (w.unit u).state.active = true ∧ (w.unit u).workflow = none

/-- `classify_waiting_work_intents_with_active_units` -/
def waitingWithActiveUnit (i : Fin nI) : Prop :=
  w.intent i = .waiting ∧ ∃ u, (w.unit u).intent = i ∧ (w.unit u).state.active = true

/-- Shared shape of the three "terminal unit, intent still open" classifiers. -/
def unitLeftIntentOpen (u : Fin nU) (s : UnitState) : Prop :=
  (w.unit u).state = s ∧ (w.intent (w.unit u).intent).isOpen = true ∧ ¬ w.activeSibling u

/-- `classify_succeeded_work_units_with_unsatisfied_intents` -/
def succeededUnsatisfied (u : Fin nU) : Prop := w.unitLeftIntentOpen u .succeeded
/-- `classify_failed_work_units_with_unfailed_intents` -/
def failedUnfailed (u : Fin nU) : Prop := w.unitLeftIntentOpen u .failed
/-- `classify_superseded_work_units_with_uncancelled_intents` -/
def supersededUncancelled (u : Fin nU) : Prop :=
  w.unitLeftIntentOpen u .cancelled ∧ (w.unit u).reason = .superseding

/-- `classify_active_child_work_units_with_terminal_parents` -/
def activeChildOfTerminal (c : Fin nU) : Prop :=
  (w.unit c).state.active = true ∧
    ∃ p, (w.unit c).parent = some p ∧ (w.unit p).state.terminal = true

/-- `classify_requested_work_intents_without_active_units` (and the dispatcher
    variant). In Ruby both return `[]` unless the reconcile was scoped to a
    `work_intent_id`; see `globalQuiescent`. Gates/fulfillment not modelled. -/
def requestedWithoutActiveUnit (i : Fin nI) : Prop :=
  w.intent i = .requested ∧ ∀ u, (w.unit u).intent = i → (w.unit u).state.active = false

instance (u : Fin nU) : Decidable (w.terminalWithLocks u) := by unfold terminalWithLocks; infer_instance
instance (u : Fin nU) : Decidable (w.activeWithoutWorkflow u) := by unfold activeWithoutWorkflow; infer_instance
instance (i : Fin nI) : Decidable (w.waitingWithActiveUnit i) := by unfold waitingWithActiveUnit; infer_instance
instance (u : Fin nU) (s) : Decidable (w.unitLeftIntentOpen u s) := by unfold unitLeftIntentOpen; infer_instance
instance (u : Fin nU) : Decidable (w.succeededUnsatisfied u) := by unfold succeededUnsatisfied; infer_instance
instance (u : Fin nU) : Decidable (w.failedUnfailed u) := by unfold failedUnfailed; infer_instance
instance (u : Fin nU) : Decidable (w.supersededUncancelled u) := by unfold supersededUncancelled; infer_instance
instance (c : Fin nU) : Decidable (w.activeChildOfTerminal c) := by unfold activeChildOfTerminal; infer_instance
instance (i : Fin nI) : Decidable (w.requestedWithoutActiveUnit i) := by unfold requestedWithoutActiveUnit; infer_instance

/-- No ownership-layer classifier fires in an *unscoped* (periodic) reconcile. -/
def globalQuiescent : Prop :=
  (∀ u, ¬ w.terminalWithLocks u) ∧ (∀ u, ¬ w.activeWithoutWorkflow u) ∧
  (∀ i, ¬ w.waitingWithActiveUnit i) ∧ (∀ u, ¬ w.succeededUnsatisfied u) ∧
  (∀ u, ¬ w.failedUnfailed u) ∧ (∀ u, ¬ w.supersededUncancelled u) ∧
  (∀ c, ¬ w.activeChildOfTerminal c)

instance : Decidable w.globalQuiescent := by unfold globalQuiescent; infer_instance

/-! ## Repairs (executor semantics: guards re-checked on the current world) -/

/-- `ReleaseTerminalWorkUnitLocks` -/
def releaseTerminalLocks (u : Fin nU) : World nI nU nK :=
  if (w.unit u).state.terminal then w.releaseAll u else w

/-- `CancelActiveWorkUnitWithoutWorkflow`: `preempt!(missing_workflow)` -/
def cancelWithoutWorkflow (u : Fin nU) : World nI nU nK :=
  if (w.unit u).state.active = true ∧ (w.unit u).workflow = none then w.preempt u .other else w

/-- `ClearWaitingWorkIntentActiveUnit`: `intent.request!` -/
def clearWaiting (i : Fin nI) : World nI nU nK :=
  if w.waitingWithActiveUnit i then w.setIntent i .requested else w

/-- `SatisfyWorkIntentFromSucceededWorkUnit` -/
def satisfyFromSucceeded (u : Fin nU) : World nI nU nK :=
  if w.succeededUnsatisfied u then w.setIntent (w.unit u).intent .satisfied else w

/-- `FailWorkIntentFromFailedWorkUnit` -/
def failFromFailed (u : Fin nU) : World nI nU nK :=
  if w.failedUnfailed u then w.setIntent (w.unit u).intent .failed else w

/-- `CancelWorkIntentFromSupersededWorkUnit` -/
def cancelFromSuperseded (u : Fin nU) : World nI nU nK :=
  if w.supersededUncancelled u then w.setIntent (w.unit u).intent .cancelled else w

/-- `CancelTerminalWorkUnitActiveChildren`, per child. The Workflow-cancel path
    is approximated by `preempt!(terminal_parent_work_unit)`. -/
def cancelChild (c : Fin nU) : World nI nU nK :=
  if w.activeChildOfTerminal c then w.preempt c .other else w

end World
end SyrusModel
