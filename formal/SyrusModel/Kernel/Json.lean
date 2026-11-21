import Lean.Data.Json
import SyrusModel.Kernel.Reconcile

/-!
# DOC-44 Phase 1 kernel: canonical JSON and an executable validity check

The oracle's input and output schema. States serialize as their constructor
names (`"running"`), records as objects with the kernel field names, and an
`Issue` as `{"kind": {...}}`. Optional fields default as in the kernel, so a
fixture lists only what it needs.

`validB` is the executable counterpart of `Valid`; `validB_sound` proves it
never claims a world is valid when it is not, so the oracle's verdict is
backed by the definition the theorems use.
-/

namespace SyrusModel
namespace Kernel

open Lean

deriving instance ToJson, FromJson for IntentState
deriving instance ToJson, FromJson for UnitState
deriving instance ToJson, FromJson for WorkflowState
deriving instance ToJson, FromJson for StepState
deriving instance ToJson, FromJson for RunState
deriving instance ToJson, FromJson for Intent
deriving instance ToJson, FromJson for Unit
deriving instance ToJson, FromJson for Workflow
deriving instance ToJson, FromJson for Step
deriving instance ToJson, FromJson for Run
deriving instance ToJson, FromJson for Lock
deriving instance ToJson for World.Issue

instance : FromJson World where
  fromJson? j := do
    let field {α : Type} [FromJson α] (name : String) : Except String (List α) :=
      match j.getObjVal? name with
      | .ok v => fromJson? v
      | .error _ => pure []
    return {
      intents := ← field "intents"
      units := ← field "units"
      workflows := ← field "workflows"
      steps := ← field "steps"
      runs := ← field "runs"
      locks := ← field "locks" }

instance : ToJson World where
  toJson w := Json.mkObj [
    ("intents", toJson w.intents), ("units", toJson w.units), ("workflows", toJson w.workflows),
    ("steps", toJson w.steps), ("runs", toJson w.runs), ("locks", toJson w.locks)]

namespace World

/-- Executable validity: the same conditions as `Valid`. -/
def validB (w : World) : Bool :=
  decide (w.intents.map Intent.id).Nodup &&
  decide (w.units.map Unit.id).Nodup &&
  decide (w.workflows.map Workflow.id).Nodup &&
  decide (w.steps.map Step.id).Nodup &&
  decide (w.runs.map Run.id).Nodup &&
  decide (w.locks.map Lock.key).Nodup &&
  w.units.all (fun u => w.intents.any (·.id == u.intent)) &&
  w.units.all (fun u => match u.workflow with
    | some wf => w.workflows.any (·.id == wf)
    | none => true) &&
  w.steps.all (fun s => w.workflows.any (·.id == s.workflow)) &&
  w.runs.all (fun r => w.steps.any (·.id == r.step)) &&
  w.locks.all (fun l => w.units.any (·.id == l.unit))

theorem any_id {α : Type} {xs : List α} {f : α → Id} {n : Id} (h : xs.any (fun x => f x == n) = true) :
    ∃ x ∈ xs, f x = n := by
  obtain ⟨x, hx, he⟩ := List.any_eq_true.mp h
  exact ⟨x, hx, by simpa using he⟩

/-- The oracle never reports an invalid world as valid. -/
theorem validB_sound {w : World} (h : w.validB = true) : w.Valid := by
  simp only [validB, Bool.and_eq_true, decide_eq_true_eq, List.all_eq_true] at h
  obtain ⟨⟨⟨⟨⟨⟨⟨⟨⟨⟨hi, hu⟩, hwf⟩, hs⟩, hr⟩, hl⟩, hui⟩, huw⟩, hsw⟩, hrs⟩, hlu⟩ := h
  exact {
    intentsUnique := hi, unitsUnique := hu, workflowsUnique := hwf, stepsUnique := hs,
    runsUnique := hr, lockKeysUnique := hl
    unitIntent := fun u hm => any_id (hui u hm)
    unitWorkflow := fun u hm wf hwf' => by
      have := huw u hm
      rw [hwf'] at this
      exact any_id this
    stepWorkflow := fun s hm => any_id (hsw s hm)
    runStep := fun r hm => any_id (hrs r hm)
    lockUnit := fun l hm => any_id (hlu l hm) }

end World
end Kernel
end SyrusModel
