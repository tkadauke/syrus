/-!
# WorkIntent / WorkUnit / WorkUnitLock: a reference model

A deliberately small, executable model of the ownership layer in
`app/models/work_unit.rb`, `app/models/work_intent.rb`,
`app/models/work_unit_lock.rb` and `app/services/work_intents/terminal_unit_sync.rb`.

Each operation mirrors one Ruby method *as written*, including the guards it
does **not** have. Where a Ruby method relies on its callers to only invoke it
in certain states, the corresponding theorem here carries that obligation as an
explicit hypothesis, and a `decide`-checked counterexample shows what happens
when a caller breaks it.

Modelling choices (each is a simplification worth knowing about):

* The set of intents, units and lock keys is fixed (`Fin n`). Creation of new
  units is not modelled yet; every operation acts on existing records.
* Locks are modelled as `holder : key → Option unit`, i.e. "the active lock for
  this key". This bakes in the database's unique index on `active_lock_key`,
  so lock mutual exclusion *per key* is true by construction. Released lock
  rows are history and are not represented.
* `preemption_reason` is abstracted to whether it is in
  `TerminalUnitSync::SUPERSEDING_CANCEL_REASONS`.
* `block!` reasons are abstracted to whether they surrender landing locks
  (`EXTERNALLY_CLEARED_BLOCKED_REASONS`, plus the urgent pre-start case).
* `nonblocking_main_branch_repair_repository_lock?` is not modelled.
* Transactions are atomic: an operation that raises (`LockConflict`) returns
  `none` and the world is unchanged.
-/

namespace SyrusModel

/-! ## States -/

inductive UnitState where
  | queued | blocked | running | succeeded | failed | cancelled
  deriving DecidableEq, Repr

namespace UnitState
/-- `WorkUnit#terminal?` — note `blocked` is *not* terminal for units. -/
def terminal : UnitState → Bool
  | succeeded | failed | cancelled => true
  | _ => false

/-- `WorkUnit#active?` -/
def active (s : UnitState) : Bool := !s.terminal

/-- An outcome worth protecting: `succeeded` or `failed`. -/
def outcome : UnitState → Bool
  | succeeded | failed => true
  | _ => false
end UnitState

inductive IntentState where
  | requested | waiting | satisfied | failed | cancelled
  deriving DecidableEq, Repr

/-- `requested? || waiting?` — the intent still wants work done. -/
def IntentState.isOpen : IntentState → Bool
  | .requested | .waiting => true
  | _ => false

inductive Reason where
  | none
  /-- in `SUPERSEDING_CANCEL_REASONS` -/
  | superseding
  /-- any other reason: `missing_workflow`, `terminal_parent_work_unit`,
      `terminal_workflow_lock_cleanup`, ... -/
  | other
  deriving DecidableEq, Repr

inductive BlockReason where
  /-- `ci_repair_disabled`, `no_capable_worker`, urgent pre-start landing:
      `block!` surrenders the unit's `landing:*` locks. -/
  | surrendersLanding
  | ordinary
  deriving DecidableEq, Repr

/-! ## World -/

structure WUnit (nI nU nK : Nat) where
  intent : Fin nI
  state : UnitState
  reason : Reason
  /-- `workflow_id`; `none` means no Workflow is attached. -/
  workflow : Option Nat
  /-- `workflow.terminal?` (which, unlike units, counts `blocked`). -/
  workflowTerminal : Bool
  parent : Option (Fin nU)
  /-- `lock_keys_for_runtime` (only consulted when a Workflow is attached). -/
  needs : Fin nK → Bool
  /-- `definition.lock_conflicts_enforced?` -/
  enforced : Bool

structure World (nI nU nK : Nat) where
  intent : Fin nI → IntentState
  unit : Fin nU → WUnit nI nU nK
  /-- The active `WorkUnitLock` for each key, if any. -/
  holder : Fin nK → Option (Fin nU)
  /-- Key starts with `landing:`. Static. -/
  landing : Fin nK → Bool

variable {nI nU nK : Nat}

def upd {α : Type} {n : Nat} (f : Fin n → α) (i : Fin n) (v : α) : Fin n → α :=
  fun j => if j = i then v else f j

@[simp] theorem upd_same {α} {n} (f : Fin n → α) (i : Fin n) (v : α) : upd f i v i = v := by
  simp [upd]

@[simp] theorem upd_other {α} {n} (f : Fin n → α) {i j : Fin n} (v : α) (h : j ≠ i) :
    upd f i v j = f j := by
  simp [upd, h]

namespace World
variable (w : World nI nU nK)

def setUnit (u : Fin nU) (f : WUnit nI nU nK → WUnit nI nU nK) : World nI nU nK :=
  { w with unit := upd w.unit u (f (w.unit u)) }

def setState (u : Fin nU) (s : UnitState) : World nI nU nK :=
  w.setUnit u (fun x => { x with state := s })

def setIntent (i : Fin nI) (s : IntentState) : World nI nU nK :=
  { w with intent := upd w.intent i s }

/-- Release the active locks held by `u` whose key satisfies `p`. -/
def releaseWhere (u : Fin nU) (p : Fin nK → Bool) : World nI nU nK :=
  { w with holder := fun k => if w.holder k = some u ∧ p k = true then none else w.holder k }

/-- `work_unit_locks.active.find_each(&:release!)` -/
def releaseAll (u : Fin nU) : World nI nU nK := w.releaseWhere u (fun _ => true)

/-- `WorkUnit#reactivate_work_intent!` -/
def reactivate (u : Fin nU) : World nI nU nK :=
  if (w.intent (w.unit u).intent).isOpen then w else w.setIntent (w.unit u).intent .requested

/-- `WorkUnit#block!`. No guard on the current state. -/
def block (u : Fin nU) (r : BlockReason) : World nI nU nK :=
  match r with
  | .surrendersLanding => ((w.reactivate u).setState u .blocked).releaseWhere u w.landing
  | .ordinary => (w.reactivate u).setState u .blocked

/-- `WorkUnit#unblock!`. No guard on the current state. -/
def unblock (u : Fin nU) : World nI nU nK :=
  (w.reactivate u).setState u .queued

/-- `same_runtime_lock_owner?` -/
def sameOwner (a b : Fin nU) : Bool :=
  a == b || ((w.unit a).workflow.isSome && (w.unit a).workflow == (w.unit b).workflow)

/-- Keys `u` must hold to run. `lock_keys_for_runtime` is `[]` without a Workflow. -/
def needsKey (u : Fin nU) (k : Fin nK) : Bool :=
  (w.unit u).workflow.isSome && (w.unit u).needs k

/-- `ensure_active_locks!` raises `LockConflict` for this key. -/
def conflict (u : Fin nU) (k : Fin nK) : Bool :=
  w.needsKey u k &&
    match w.holder k with
    | some o => (w.unit u).enforced && !w.sameOwner u o
    | none => false

/-- `ensure_active_locks!`: take every needed free key, or raise. A key held by a
    same-runtime owner, or by anyone when conflicts are not enforced, is
    *skipped* — the unit proceeds without holding it. -/
def ensureLocks (u : Fin nU) : Option (World nI nU nK) :=
  if ∃ k, w.conflict u k = true then none
  else some { w with holder := fun k => if w.needsKey u k ∧ w.holder k = none then some u else w.holder k }

/-- `WorkUnit#mark_running!`. No guard on the current state. -/
def markRunning (u : Fin nU) : Option (World nI nU nK) :=
  ((w.reactivate u).ensureLocks u).map (fun w' => w'.setState u .running)

def activeSibling (u : Fin nU) : Prop :=
  ∃ v, v ≠ u ∧ (w.unit v).intent = (w.unit u).intent ∧ (w.unit v).state.active = true

instance (u : Fin nU) : Decidable (w.activeSibling u) := by
  unfold activeSibling; infer_instance

/-- `WorkIntents::TerminalUnitSync.call` -/
def sync (u : Fin nU) : World nI nU nK :=
  if (w.unit u).state.terminal = true ∧ (w.intent (w.unit u).intent).isOpen = true ∧
      ¬ w.activeSibling u then
    match (w.unit u).state, (w.unit u).reason with
    | .succeeded, _ => w.setIntent (w.unit u).intent .satisfied
    | .failed, _ => w.setIntent (w.unit u).intent .failed
    | .cancelled, .superseding => w.setIntent (w.unit u).intent .cancelled
    | _, _ => w
  else w

/-- `WorkUnit#mark_terminal!(s)`. Raises unless `s` is terminal, but does **not**
    check that the unit is still active. -/
def markTerminal (u : Fin nU) (s : UnitState) : Option (World nI nU nK) :=
  if s.terminal then some (((w.setState u s).releaseAll u).sync u) else none

/-- `WorkUnit#preempt!` -/
def preempt (u : Fin nU) (r : Reason) : World nI nU nK :=
  if (w.unit u).state = .cancelled then
    (w.setUnit u (fun x => { x with reason := if x.reason = .none then r else x.reason })).sync u
  else if (w.unit u).state.active then
    ((w.setUnit u (fun x => { x with state := .cancelled, reason := r })).releaseAll u).sync u
  else w

end World

/-! ## Invariants -/

namespace World
variable (w : World nI nU nK)

/-- Only active units hold locks (what `classify_terminal_work_units_with_active_locks` checks). -/
def LocksOnlyActive : Prop :=
  ∀ k u, w.holder k = some u → (w.unit u).state.active = true

/-- An active unit's intent is still open. -/
def ActiveIntentOpen : Prop :=
  ∀ u, (w.unit u).state.active = true → (w.intent (w.unit u).intent).isOpen = true

def Inv : Prop := w.LocksOnlyActive ∧ w.ActiveIntentOpen

/-- A unit that reached `succeeded`/`failed` keeps that outcome. -/
def OutcomesKept (w' : World nI nU nK) : Prop :=
  ∀ u, (w.unit u).state.outcome = true → (w'.unit u).state = (w.unit u).state

/-- A running unit that enforces conflicts actually holds (or shares) every key
    it needs. This is the property lock mutual exclusion is *for*. -/
def RunningHoldsLocks : Prop :=
  ∀ u k, (w.unit u).state = .running → (w.unit u).enforced = true → w.needsKey u k = true →
    ∃ o, w.holder k = some o ∧ w.sameOwner u o = true

instance : Decidable w.LocksOnlyActive := by unfold LocksOnlyActive; infer_instance
instance : Decidable w.ActiveIntentOpen := by unfold ActiveIntentOpen; infer_instance
instance : Decidable w.Inv := by unfold Inv; infer_instance
instance (w' : World nI nU nK) : Decidable (w.OutcomesKept w') := by unfold OutcomesKept; infer_instance
instance : Decidable w.RunningHoldsLocks := by unfold RunningHoldsLocks; infer_instance

end World

end SyrusModel

namespace SyrusModel
namespace World
variable {nI nU nK : Nat} (w : World nI nU nK)

/-- At most one WorkUnit per Workflow (`Workflow has_one :work_unit`). The
    schema has only a non-unique index on `work_units.workflow_id`, so this is
    an application-level assumption, not a database guarantee. -/
def UniqueRuntime : Prop :=
  ∀ a b, (w.unit a).workflow.isSome = true → (w.unit a).workflow = (w.unit b).workflow → a = b

instance : Decidable w.UniqueRuntime := by unfold UniqueRuntime; infer_instance

end World
end SyrusModel
