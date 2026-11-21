import SyrusModel.Kernel.Basic

/-!
# DOC-44 Phase 1 kernel: terminal cleanup, diagnose and reconcile

The terminal-cleanup family of the reconciler, as pure functions:

| issue | repair | Ruby |
| --- | --- | --- |
| `activeRunUnderTerminalWorkflow` | cancel the Run | `CancelTerminalWorkflowActiveDescendants` |
| `activeStepUnderTerminalWorkflow` | cancel the Step | same |
| `activeRunOnTerminalStep` | skip the Run | `classify_active_runs_on_terminal_steps` |
| `activeUnitBehindTerminalWorkflow` | the unit takes the Workflow's outcome | `WorkUnits::TerminalWorkflowSync` |
| `lockOfInactiveUnit` | release the lock | `classify_terminal_work_units_with_active_locks` |

A `blocked` Workflow is terminal, but its unit stays active (DOC-44): the
unit-sync repair skips it.

An active Run under a finished Workflow is cancelled; an active Run on a
finished Step of a live Workflow is skipped (`skip_obsolete_run`). Phase 2
differential testing found the second rule missing from the first kernel.

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

/-- The Run's Step has finished (`Step#terminal?`: anything but queued or running). -/
def runStepTerminal (w : World) (r : Run) : Bool :=
  match w.steps.find? (·.id == r.step) with
  | some s => !s.state.active
  | none => false

/-- Terminal cleanup touches the Run: it is active and its Workflow or its Step
    has finished. -/
def runStale (w : World) (r : Run) : Bool :=
  r.state.active && (w.runWorkflowTerminal r || w.runStepTerminal r)

/-- Cancelled under a finished Workflow, otherwise skipped as obsolete. -/
def runTarget (w : World) (r : Run) : RunState :=
  if w.runWorkflowTerminal r then .cancelled else .skipped

def fixRun (w : World) (r : Run) : Run :=
  if w.runStale r then { r with state := w.runTarget r } else r

def fixStep (w : World) (s : Step) : Step :=
  if w.stepStale s then { s with state := .cancelled } else s

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
  | activeRunOnTerminalStep (run : Id)
  | activeStepUnderTerminalWorkflow (step : Id)
  | activeUnitBehindTerminalWorkflow (unit : Id) (target : UnitState)
  | lockOfInactiveUnit (key : String)
  deriving DecidableEq, Repr

def runIssue (w : World) (r : Run) : Option Issue :=
  if w.runStale r then
    some (if w.runWorkflowTerminal r then .activeRunUnderTerminalWorkflow r.id else .activeRunOnTerminalStep r.id)
  else none

def diagnose (w : World) : List Issue :=
  w.runs.filterMap w.runIssue ++
  (w.steps.filter (fun s => w.stepStale s)).map (Issue.activeStepUnderTerminalWorkflow ·.id) ++
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

theorem stepStale_reconcile (w : World) (s : Step) : w.reconcile.stepStale s = w.stepStale s := rfl

theorem stepStale_fixStep_workflow (w w' : World) (s : Step) (st : StepState) :
    w'.stepStale { w.fixStep s with state := st } = w'.stepStale { s with state := st } := by
  simp [stepStale, fixStep_workflow]

theorem stepStale_cancelled (w : World) (s : Step) : w.stepStale { s with state := .cancelled } = false := by
  unfold stepStale
  cases w.workflowState? s.workflow with
  | none => rfl
  | some st => cases st <;> rfl

theorem fixStep_idem (w : World) (s : Step) : w.reconcile.fixStep (w.fixStep s) = w.fixStep s := by
  unfold fixStep
  by_cases h : w.stepStale s = true
  · simp only [h, if_true]
    rw [stepStale_reconcile, stepStale_cancelled]; simp
  · simp only [h, if_false, Bool.false_eq_true]
    rw [stepStale_reconcile]; simp [h]

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

theorem fixRun_pos (w : World) {r : Run} (h : w.runStale r = true) :
    w.fixRun r = { r with state := w.runTarget r } := by simp [fixRun, h]

theorem fixRun_neg (w : World) {r : Run} (h : ¬ w.runStale r = true) :
    w.fixRun r = r := by simp [fixRun, h]

theorem fixStep_pos (w : World) {s : Step} (h : w.stepStale s = true) :
    w.fixStep s = { s with state := .cancelled } := by simp [fixStep, h]

theorem fixStep_neg (w : World) {s : Step} (h : ¬ w.stepStale s = true) :
    w.fixStep s = s := by simp [fixStep, h]

theorem stepStale_terminal (w : World) (s : Step) (h : w.stepStale s = true) : w.stepWorkflowTerminal s = true := by
  unfold stepStale at h
  unfold stepWorkflowTerminal
  cases hw : w.workflowState? s.workflow with
  | none => simp [hw] at h
  | some st => cases st <;> simp_all [WorkflowState.terminal]

theorem runTarget_inactive (w : World) (r : Run) : (w.runTarget r).active = false := by
  unfold runTarget; split <;> rfl

/-- While the Run's Workflow is live, cleanup leaves its Step alone, so whether
    the Step has finished is the same before and after. -/
theorem runStepTerminal_reconcile_of_live (w : World) {r : Run} (h : w.runWorkflowTerminal r = false) :
    w.reconcile.runStepTerminal r = w.runStepTerminal r := by
  unfold runStepTerminal
  show (match (w.steps.map w.fixStep).find? (·.id == r.step) with
    | some s => !s.state.active | none => false) = _
  rw [find?_fixStep]
  unfold runWorkflowTerminal at h
  cases hf : w.steps.find? (·.id == r.step) with
  | none => rfl
  | some s =>
    simp only [hf] at h
    have hs : ¬ w.stepStale s = true := fun hc => by
      rw [stepStale_terminal w s hc] at h; exact Bool.noConfusion h
    simp only [Option.map_some]
    rw [fixStep_neg w hs]

theorem runStale_reconcile_neg (w : World) {r : Run} (h : ¬ w.runStale r = true) :
    w.reconcile.runStale r = false := by
  unfold runStale at h ⊢
  cases ha : r.state.active with
  | false => rfl
  | true =>
    rw [ha] at h
    have hw : w.runWorkflowTerminal r = false := by
      cases hw : w.runWorkflowTerminal r <;> simp_all
    have hs : w.runStepTerminal r = false := by
      cases hs : w.runStepTerminal r <;> simp_all
    rw [runWorkflowTerminal_reconcile, hw, runStepTerminal_reconcile_of_live w hw, hs]; rfl

theorem runStale_target (w w' : World) (r : Run) : w'.runStale { r with state := w.runTarget r } = false := by
  simp [runStale, runTarget_inactive]

theorem fixRun_clean (w : World) (r : Run) : ¬ w.reconcile.runStale (w.fixRun r) = true := by
  by_cases h : w.runStale r = true
  · rw [fixRun_pos w h, runStale_target]; simp
  · rw [fixRun_neg w h, runStale_reconcile_neg w h]; simp

theorem fixRun_idem (w : World) (r : Run) : w.reconcile.fixRun (w.fixRun r) = w.fixRun r :=
  fixRun_neg w.reconcile (fixRun_clean w r)

theorem fixStep_clean (w : World) (s : Step) : ¬ w.reconcile.stepStale (w.fixStep s) = true := by
  rw [stepStale_reconcile]
  by_cases h : w.stepStale s = true
  · rw [fixStep_pos w h, stepStale_cancelled]; simp
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
  have hr : w.reconcile.runs.filterMap w.reconcile.runIssue = [] := by
    rw [List.filterMap_eq_nil_iff]
    intro r hr
    obtain ⟨r0, _, rfl⟩ := List.mem_map.mp hr
    have hc := fixRun_clean w r0
    simp [runIssue, hc]
  have hs : w.reconcile.steps.filter (fun s => w.reconcile.stepStale s) = [] := by
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
