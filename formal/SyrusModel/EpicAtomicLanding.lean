/-!
# DOC-44 Phase 3: an Epic child never lands on its own

DOC-44: "Epic members remain one atomic landing unit where required."

`LandingQueueProcessor` has two landing entry points: the inline door
`try_land!(job)` and the ordered pass `call`. Both route an Epic child to
`MergeTrainDispatcher.try_dispatch!(epic)` before the per-Job path:
`try_land!` checks `merge_train_for_epic_child?` before `blockage_for`, and
`call` groups entries into landing units (an Epic is one unit) and sends a
train unit to the dispatcher. `land(job)`, which starts `auto_merge`, is reached
only through the per-Job branch of either.

The `waiting_epic_merge_train` blocker itself is overridable, so the per-Job
gate alone would not hold an Epic child; the routing does. Proved:
`land` is never reached for an Epic child, whatever the blockers and overrides
(`epic_child_never_lands_alone`). Pinned by `landing_queue_processor_spec.rb`
"never lands an Epic child on its own, even with an override of the train
wait". No bug found.
-/

namespace SyrusModel
namespace EpicAtomicLanding

structure Job where
  epic : Option Nat
  bundleEligible : Bool
  /-- `blockage_for(job)` came back clear (overrides included). -/
  unblocked : Bool
  deriving DecidableEq, Repr

inductive Dispatch where
  | mergeTrain (epic : Nat)
  | jobBundle
  | landSolo
  | none
  deriving DecidableEq, Repr

/-- `try_land!` -/
def tryLand (j : Job) : Dispatch :=
  match j.epic with
  | some e => .mergeTrain e
  | none => if j.bundleEligible then .jobBundle else if j.unblocked then .landSolo else .none

/-- `call`: a landing unit keyed by Epic for Epic children
    (`merge_train_unit?` on its first entry; every entry shares the Epic). -/
def callUnit (first : Job) (eligible : Option Job) : Dispatch :=
  match first.epic with
  | some e => .mergeTrain e
  | none =>
    if first.bundleEligible then .jobBundle
    else match eligible with
      | some j => if j.unblocked then .landSolo else .none
      | none => .none

theorem epic_child_never_lands_alone (j : Job) (e : Nat) (h : j.epic = some e) :
    tryLand j ≠ .landSolo ∧ ∀ eligible, callUnit j eligible ≠ .landSolo := by
  refine ⟨?_, fun _ => ?_⟩ <;> simp [tryLand, callUnit, h]

end EpicAtomicLanding
end SyrusModel
