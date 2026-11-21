/-!
# DOC-44 Phase 1 kernel: the world

The core execution graph from DOC-44, as one executable value:

```
WorkIntent → WorkUnit → Workflow → Step → Run
                ↓
              Locks
```

Unlike the earlier focused models (which index a fixed universe with `Fin n`
for proof convenience), entities here are lists keyed by logical ids, so the
same definitions run in the executable oracle on JSON input (DOC-44,
"Executable Lean oracle") and are reasoned about in proofs.

States mirror the AASM machines (`app/models/{work_intent,work_unit,workflow,
step,run}.rb`). The semantic distinction DOC-44 requires is kept explicit: a
`blocked` Workflow is terminal for the Workflow machine, while a `blocked`
WorkUnit is active and recoverable.
-/

namespace SyrusModel
namespace Kernel

abbrev Id := Nat

inductive IntentState where
  | requested | waiting | satisfied | failed | cancelled
  deriving DecidableEq, Repr, Inhabited

inductive UnitState where
  | queued | blocked | running | succeeded | failed | cancelled
  deriving DecidableEq, Repr, Inhabited

inductive WorkflowState where
  | queued | running | succeeded | failed | cancelled | blocked
  deriving DecidableEq, Repr, Inhabited

inductive StepState where
  | queued | running | succeeded | failed | cancelled | skipped | blocked
  deriving DecidableEq, Repr, Inhabited

inductive RunState where
  | queued | running | succeeded | failed | cancelled | skipped | blocked
  deriving DecidableEq, Repr, Inhabited

def UnitState.active : UnitState → Bool
  | .queued | .blocked | .running => true
  | _ => false

/-- `Workflow.terminal` in Ruby counts `blocked`. -/
def WorkflowState.terminal : WorkflowState → Bool
  | .queued | .running => false
  | _ => true

def StepState.active : StepState → Bool
  | .queued | .running => true
  | _ => false

def RunState.active : RunState → Bool
  | .queued | .running => true
  | _ => false

structure Intent where
  id : Id
  state : IntentState
  deriving DecidableEq, Repr

structure Unit where
  id : Id
  intent : Id
  workflow : Option Id
  state : UnitState
  deriving DecidableEq, Repr

structure Workflow where
  id : Id
  state : WorkflowState
  deriving DecidableEq, Repr

structure Step where
  id : Id
  workflow : Id
  state : StepState
  deriving DecidableEq, Repr

structure Run where
  id : Id
  step : Id
  state : RunState
  deriving DecidableEq, Repr

/-- An active lock row: `key` is held by `unit`. -/
structure Lock where
  key : String
  unit : Id
  deriving DecidableEq, Repr

structure World where
  intents : List Intent := []
  units : List Unit := []
  workflows : List Workflow := []
  steps : List Step := []
  runs : List Run := []
  locks : List Lock := []
  deriving DecidableEq, Repr

namespace World

def workflowState? (w : World) (id : Id) : Option WorkflowState :=
  (w.workflows.find? (·.id == id)).map (·.state)

def unitState? (w : World) (id : Id) : Option UnitState :=
  (w.units.find? (·.id == id)).map (·.state)

/-- The Workflow a Step belongs to has finished (including `blocked`). -/
def stepWorkflowTerminal (w : World) (s : Step) : Bool :=
  match w.workflowState? s.workflow with
  | some st => st.terminal
  | none => false

/-- The Workflow a Run belongs to (through its Step) has finished. -/
def runWorkflowTerminal (w : World) (r : Run) : Bool :=
  match w.steps.find? (·.id == r.step) with
  | some s => w.stepWorkflowTerminal s
  | none => false

/-- The unit holding a lock is active. -/
def lockHolderActive (w : World) (l : Lock) : Bool :=
  match w.unitState? l.unit with
  | some st => st.active
  | none => false

/-! ## Validity

`valid` is referential integrity plus the invariants the database enforces
(unique ids, one active holder per lock key). It is the precondition every
kernel function assumes and every transition must preserve; drift that the
reconciler repairs is *not* invalidity. -/

def idsUnique {α : Type} (ids : α → Id) (xs : List α) : Prop := (xs.map ids).Nodup

structure Valid (w : World) : Prop where
  intentsUnique : idsUnique Intent.id w.intents
  unitsUnique : idsUnique Unit.id w.units
  workflowsUnique : idsUnique Workflow.id w.workflows
  stepsUnique : idsUnique Step.id w.steps
  runsUnique : idsUnique Run.id w.runs
  /-- `idx_work_unit_locks_active_key_unique` -/
  lockKeysUnique : (w.locks.map Lock.key).Nodup
  unitIntent : ∀ u ∈ w.units, ∃ i ∈ w.intents, i.id = u.intent
  unitWorkflow : ∀ u ∈ w.units, ∀ wf, u.workflow = some wf → ∃ x ∈ w.workflows, x.id = wf
  stepWorkflow : ∀ s ∈ w.steps, ∃ x ∈ w.workflows, x.id = s.workflow
  runStep : ∀ r ∈ w.runs, ∃ s ∈ w.steps, s.id = r.step
  lockUnit : ∀ l ∈ w.locks, ∃ u ∈ w.units, u.id = l.unit

end World
end Kernel
end SyrusModel
