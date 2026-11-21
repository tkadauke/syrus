import SyrusModel.Kernel.Basic

/-!
# DOC-44 Phase 1 kernel: terminal cleanup, diagnose and reconcile

The terminal-cleanup family of the reconciler, as pure functions:

| issue | repair | Ruby |
| --- | --- | --- |
| `activeRunUnderTerminalWorkflow` | cancel the Run | `CancelTerminalWorkflowActiveDescendants` |
| `activeStepUnderTerminalWorkflow` | cancel the Step | same |
| `activeUnitBehindTerminalWorkflow` | the unit takes the Workflow's outcome | `WorkUnits::TerminalWorkflowSync` |
| `lockOfInactiveUnit` | release the lock | `classify_terminal_work_units_with_active_locks` |

A `blocked` Workflow is terminal, but its unit stays active (DOC-44): the
unit-sync repair skips it.

Proved here:

* `diagnose_reconcile`: reconciliation leaves none of its own issues behind;
* `reconcile_idem`: reconciling twice is reconciling once (DOC-44, "Applying
  the same repair twice is a no-op after the first successful application",
  "repeated reconciliation reaches a fixed point");
* `reconcile_workflows`, `reconcile_intents`: the repairs never touch Workflow
  or intent state (their scope).
-/

namespace SyrusModel
namespace Kernel

/-- The unit outcome a finished Workflow implies; `none` for `blocked` (the
    unit stays active and recoverable) and for non-terminal Workflows. -/
def unitOutcome : WorkflowState → Option UnitState
  | .succeeded => some .succeeded
  | .failed => some .failed
  | .cancelled => some .cancelled
  | _ => none

namespace World

def fixRun (w : World) (r : Run) : Run :=
  if w.runWorkflowTerminal r && r.state.active then { r with state := .cancelled } else r

def fixStep (w : World) (s : Step) : Step :=
  if w.stepWorkflowTerminal s && s.state.active then { s with state := .cancelled } else s

/-- The state the unit sync gives a unit, if it changes it. -/
def unitTarget (w : World) (u : Unit) : Option UnitState :=
  if u.state.active then
    match u.workflow with
    | some wf => (w.workflowState? wf).bind unitOutcome
    | none => none
  else none

def fixUnit (w : World) (u : Unit) : Unit :=
  match w.unitTarget u with
  | some st => { u with state := st }
  | none => u

/-- A lock survives if its holder is active after the unit sync. -/
def lockKeep (w : World) (l : Lock) : Bool :=
  match w.units.find? (·.id == l.unit) with
  | some u => (w.fixUnit u).state.active
  | none => false

def reconcile (w : World) : World :=
  { w with
    runs := w.runs.map w.fixRun
    steps := w.steps.map w.fixStep
    units := w.units.map w.fixUnit
    locks := w.locks.filter w.lockKeep }

/-! ## Issues -/

inductive Issue where
  | activeRunUnderTerminalWorkflow (run : Id)
  | activeStepUnderTerminalWorkflow (step : Id)
  | activeUnitBehindTerminalWorkflow (unit : Id) (target : UnitState)
  | lockOfInactiveUnit (key : String)
  deriving DecidableEq, Repr

def diagnose (w : World) : List Issue :=
  (w.runs.filter (fun r => w.runWorkflowTerminal r && r.state.active)).map (Issue.activeRunUnderTerminalWorkflow ·.id) ++
  (w.steps.filter (fun s => w.stepWorkflowTerminal s && s.state.active)).map (Issue.activeStepUnderTerminalWorkflow ·.id) ++
  w.units.filterMap (fun u => (w.unitTarget u).map (Issue.activeUnitBehindTerminalWorkflow u.id)) ++
  (w.locks.filter (fun l => !w.lockKeep l)).map (Issue.lockOfInactiveUnit ·.key)

/-! ## What reconcile preserves -/

@[simp] theorem reconcile_workflows (w : World) : w.reconcile.workflows = w.workflows := rfl
@[simp] theorem reconcile_intents (w : World) : w.reconcile.intents = w.intents := rfl

theorem reconcile_workflowState? (w : World) (id : Id) :
    w.reconcile.workflowState? id = w.workflowState? id := rfl

theorem fixStep_id (w : World) (s : Step) : (w.fixStep s).id = s.id := by
  unfold fixStep; split <;> rfl

theorem fixStep_workflow (w : World) (s : Step) : (w.fixStep s).workflow = s.workflow := by
  unfold fixStep; split <;> rfl

theorem fixRun_step (w : World) (r : Run) : (w.fixRun r).step = r.step := by
  unfold fixRun; split <;> rfl

theorem fixUnit_id (w : World) (u : Unit) : (w.fixUnit u).id = u.id := by
  unfold fixUnit; split <;> rfl

theorem fixUnit_workflow (w : World) (u : Unit) : (w.fixUnit u).workflow = u.workflow := by
  unfold fixUnit; split <;> rfl

theorem stepWorkflowTerminal_reconcile (w : World) (s : Step) :
    w.reconcile.stepWorkflowTerminal s = w.stepWorkflowTerminal s := rfl

theorem stepWorkflowTerminal_fixStep (w w' : World) (s : Step) :
    w'.stepWorkflowTerminal (w.fixStep s) = w'.stepWorkflowTerminal s := by
  simp [stepWorkflowTerminal, fixStep_workflow]

theorem find?_fixStep (w : World) (id : Id) :
    (w.steps.map w.fixStep).find? (·.id == id) = (w.steps.find? (·.id == id)).map w.fixStep := by
  have hp : ((fun x : Step => x.id == id) ∘ w.fixStep) = (fun x => x.id == id) := by
    funext s; simp [Function.comp, fixStep_id]
  rw [List.find?_map, hp]

theorem runWorkflowTerminal_reconcile (w : World) (r : Run) :
    w.reconcile.runWorkflowTerminal r = w.runWorkflowTerminal r := by
  unfold runWorkflowTerminal
  show (match (w.steps.map w.fixStep).find? (·.id == r.step) with
    | some s => w.reconcile.stepWorkflowTerminal s | none => false) = _
  rw [find?_fixStep]
  cases w.steps.find? (·.id == r.step) with
  | none => rfl
  | some s =>
    show w.reconcile.stepWorkflowTerminal (w.fixStep s) = w.stepWorkflowTerminal s
    rw [stepWorkflowTerminal_fixStep, stepWorkflowTerminal_reconcile]

theorem runWorkflowTerminal_fixRun (w w' : World) (r : Run) :
    w'.runWorkflowTerminal (w.fixRun r) = w'.runWorkflowTerminal r := by
  simp [runWorkflowTerminal, fixRun_step]

/-! ## Each fix is idempotent against the reconciled world -/

theorem fixRun_idem (w : World) (r : Run) : w.reconcile.fixRun (w.fixRun r) = w.fixRun r := by
  have ht := runWorkflowTerminal_reconcile w (w.fixRun r)
  rw [runWorkflowTerminal_fixRun] at ht
  unfold fixRun at *
  by_cases h : (w.runWorkflowTerminal r && r.state.active) = true
  · simp only [h, if_true] at ht ⊢
    simp [ht, RunState.active]
  · simp only [h, if_false, Bool.false_eq_true] at ht ⊢
    rw [ht]; simp [h]

theorem fixStep_idem (w : World) (s : Step) : w.reconcile.fixStep (w.fixStep s) = w.fixStep s := by
  unfold fixStep
  by_cases h : (w.stepWorkflowTerminal s && s.state.active) = true
  · simp only [h, if_true]
    simp [stepWorkflowTerminal, StepState.active]
  · simp only [h, if_false, Bool.false_eq_true]
    rw [stepWorkflowTerminal_reconcile]; simp [h]

theorem unitOutcome_inactive {st : WorkflowState} {u : UnitState} (h : unitOutcome st = some u) :
    u.active = false := by
  cases st <;> simp [unitOutcome] at h <;> subst h <;> rfl

theorem unitTarget_fixUnit (w : World) (u : Unit) : w.reconcile.unitTarget (w.fixUnit u) = none := by
  unfold fixUnit
  cases ht : w.unitTarget u with
  | none =>
    simp only
    unfold unitTarget at ht ⊢
    by_cases ha : u.state.active = true
    · simp only [ha, if_true] at ht ⊢
      rw [show w.reconcile.workflowState? = w.workflowState? from rfl]
      exact ht
    · simp [ha]
  | some st =>
    simp only
    unfold unitTarget at ht ⊢
    by_cases ha : u.state.active = true
    · simp only [ha, if_true] at ht
      have hin : st.active = false := by
        cases hwf : u.workflow with
        | none => simp [hwf] at ht
        | some wf =>
          simp only [hwf, Option.bind_eq_some_iff] at ht
          obtain ⟨ws, _, hu⟩ := ht
          exact unitOutcome_inactive hu
      simp [hin]
    · simp [ha] at ht

theorem fixUnit_idem (w : World) (u : Unit) : w.reconcile.fixUnit (w.fixUnit u) = w.fixUnit u := by
  have h := unitTarget_fixUnit w u
  show (match w.reconcile.unitTarget (w.fixUnit u) with
    | some st => { w.fixUnit u with state := st }
    | none => w.fixUnit u) = w.fixUnit u
  rw [h]

theorem find?_fixUnit (w : World) (id : Id) :
    (w.units.map w.fixUnit).find? (·.id == id) = (w.units.find? (·.id == id)).map w.fixUnit := by
  have hp : ((fun x : Unit => x.id == id) ∘ w.fixUnit) = (fun x => x.id == id) := by
    funext u; simp [Function.comp, fixUnit_id]
  rw [List.find?_map, hp]

theorem lockKeep_reconcile (w : World) (l : Lock) : w.reconcile.lockKeep l = w.lockKeep l := by
  unfold lockKeep
  show (match (w.units.map w.fixUnit).find? (·.id == l.unit) with
    | some u => (w.reconcile.fixUnit u).state.active | none => false) = _
  rw [find?_fixUnit]
  cases w.units.find? (·.id == l.unit) with
  | none => rfl
  | some u => simp only [Option.map_some]; rw [fixUnit_idem]

theorem fixRun_pos (w : World) {r : Run} (h : (w.runWorkflowTerminal r && r.state.active) = true) :
    w.fixRun r = { r with state := .cancelled } := by simp [fixRun, h]

theorem fixRun_neg (w : World) {r : Run} (h : ¬ (w.runWorkflowTerminal r && r.state.active) = true) :
    w.fixRun r = r := by simp [fixRun, h]

theorem fixStep_pos (w : World) {s : Step} (h : (w.stepWorkflowTerminal s && s.state.active) = true) :
    w.fixStep s = { s with state := .cancelled } := by simp [fixStep, h]

theorem fixStep_neg (w : World) {s : Step} (h : ¬ (w.stepWorkflowTerminal s && s.state.active) = true) :
    w.fixStep s = s := by simp [fixStep, h]

theorem fixRun_clean (w : World) (r : Run) :
    ¬ (w.reconcile.runWorkflowTerminal (w.fixRun r) && (w.fixRun r).state.active) = true := by
  rw [runWorkflowTerminal_fixRun, runWorkflowTerminal_reconcile]
  by_cases h : (w.runWorkflowTerminal r && r.state.active) = true
  · rw [fixRun_pos w h]; simp [RunState.active]
  · rw [fixRun_neg w h]; exact h

theorem fixStep_clean (w : World) (s : Step) :
    ¬ (w.reconcile.stepWorkflowTerminal (w.fixStep s) && (w.fixStep s).state.active) = true := by
  rw [stepWorkflowTerminal_fixStep, stepWorkflowTerminal_reconcile]
  by_cases h : (w.stepWorkflowTerminal s && s.state.active) = true
  · rw [fixStep_pos w h]; simp [StepState.active]
  · rw [fixStep_neg w h]; exact h

/-! ## The theorems -/

/-- Reconciling twice is reconciling once. -/
theorem reconcile_idem (w : World) : w.reconcile.reconcile = w.reconcile := by
  have hr : w.reconcile.runs.map w.reconcile.fixRun = w.reconcile.runs := by
    show (w.runs.map w.fixRun).map w.reconcile.fixRun = w.runs.map w.fixRun
    rw [List.map_map]; congr 1; funext r; exact fixRun_idem w r
  have hs : w.reconcile.steps.map w.reconcile.fixStep = w.reconcile.steps := by
    show (w.steps.map w.fixStep).map w.reconcile.fixStep = w.steps.map w.fixStep
    rw [List.map_map]; congr 1; funext s; exact fixStep_idem w s
  have hu : w.reconcile.units.map w.reconcile.fixUnit = w.reconcile.units := by
    show (w.units.map w.fixUnit).map w.reconcile.fixUnit = w.units.map w.fixUnit
    rw [List.map_map]; congr 1; funext u; exact fixUnit_idem w u
  have hl : w.reconcile.locks.filter w.reconcile.lockKeep = w.reconcile.locks := by
    show (w.locks.filter w.lockKeep).filter w.reconcile.lockKeep = w.locks.filter w.lockKeep
    rw [List.filter_filter]; congr 1; funext l; rw [lockKeep_reconcile]; simp
  unfold reconcile at hr hs hu hl ⊢
  simp only at hr hs hu hl ⊢
  rw [hr, hs, hu, hl]

/-- Reconciliation leaves none of its own issues behind. -/
theorem diagnose_reconcile (w : World) : w.reconcile.diagnose = [] := by
  have hr : w.reconcile.runs.filter (fun r => w.reconcile.runWorkflowTerminal r && r.state.active) = [] := by
    rw [List.filter_eq_nil_iff]
    intro r hr
    obtain ⟨r0, _, rfl⟩ := List.mem_map.mp hr
    exact fixRun_clean w r0
  have hs : w.reconcile.steps.filter (fun s => w.reconcile.stepWorkflowTerminal s && s.state.active) = [] := by
    rw [List.filter_eq_nil_iff]
    intro s hs
    obtain ⟨s0, _, rfl⟩ := List.mem_map.mp hs
    exact fixStep_clean w s0
  have hu : w.reconcile.units.filterMap (fun u => (w.reconcile.unitTarget u).map (Issue.activeUnitBehindTerminalWorkflow u.id)) = [] := by
    rw [List.filterMap_eq_nil_iff]
    intro u hu
    obtain ⟨u0, _, rfl⟩ := List.mem_map.mp hu
    rw [unitTarget_fixUnit]; rfl
  have hl : w.reconcile.locks.filter (fun l => !w.reconcile.lockKeep l) = [] := by
    rw [List.filter_eq_nil_iff]
    intro l hl
    have hk : w.lockKeep l = true := (List.mem_filter.mp hl).2
    rw [lockKeep_reconcile, hk]; simp
  unfold diagnose
  rw [hr, hs, hu, hl]
  rfl

end World
end Kernel
end SyrusModel
