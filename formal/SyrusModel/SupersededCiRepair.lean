/-!
# A CI repair whose base main has moved past is cancelled, wherever it is held

The CI repair gate parks a repair for one of several reasons. Two of them wait
on the repair's own base commit: `base_not_known_healthy` (waiting for that
base to be graded) and `base_repair_active` (behind a main repair of that
base). Once main has moved past the base, neither can ever clear for this
repair, so the repair is moot and is cancelled as superseded.

Main's `39f7f9c254` taught the running path (`RepairExecutor`'s
`cancel_superseded_ci_repair`) the second kind. The queued path
(`CancelSupersededCiRepair`) and the reconciler's detection still accepted only
the first, so a repair still queued behind a stale main repair waited forever
(`queued_before_parks`). Now all paths read
`CiRepairSafety::SUPERSEDABLE_BLOCK_KINDS`.
-/

namespace SyrusModel
namespace SupersededCiRepair

inductive Block where
  | disabled | baseShaUnknown | branchBehind | baseRepairActive | baseNotKnownHealthy | duplicate
  deriving DecidableEq, Repr

/-- Blocks that wait on the repair's own base and can never clear once main
moved past it. -/
def waitsOnOwnBase : Block → Bool
  | .baseRepairActive | .baseNotKnownHealthy => true
  | _ => false

inductive Phase where
  | queued | running
  deriving DecidableEq, Repr

/-- Whether a superseded-base repair held by `b` is cancelled, before. -/
def cancelsBefore : Phase → Block → Bool
  | .running, b => waitsOnOwnBase b
  | .queued, b => b == .baseNotKnownHealthy

/-- After: both phases read one list. -/
def cancelsAfter (_ : Phase) (b : Block) : Bool := waitsOnOwnBase b

def blocks : List Block := [.disabled, .baseShaUnknown, .branchBehind, .baseRepairActive, .baseNotKnownHealthy, .duplicate]
def phases : List Phase := [.queued, .running]

/-- Before: a queued repair behind a stale main repair is never cancelled. -/
theorem queued_before_parks : cancelsBefore .queued .baseRepairActive = false := by decide

/-- After: in every phase, a superseded repair is cancelled exactly when its
block waits on its own base. -/
theorem after_cancels_exactly_moot : ∀ p ∈ phases, ∀ b ∈ blocks, cancelsAfter p b = waitsOnOwnBase b := by decide

/-- After: the queued and running paths agree. -/
theorem after_phases_agree : ∀ b ∈ blocks, cancelsAfter .queued b = cancelsAfter .running b := by decide

end SupersededCiRepair
end SyrusModel
