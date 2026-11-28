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

A third block is moot without any base comparison: `branch_behind_base`. A
branch behind its base may not be repaired until it is rebased, and starting a
rebase preempts every CI repair on the Job, so whatever clears the block
cancels the repair or moves the head it was dispatched for. Before, it was
never cancelled (`behind_before_parks`): a CI repair deferred while the agent
provider was out, then blocked behind a moved main on a queued Job, held the
Job's own retry forever, since nothing rebases a queued Job. Now every path
reads `CiRepairSafety.moot_block?`, which cancels a behind-base repair while
the branch is still behind (`moot_cancels_behind`) and leaves every other
block's answer as it was (`moot_keeps_base_blocks`).
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

/-- Blocks moot by themselves (`CiRepairSafety::BEHIND_BASE_BLOCK_KINDS`),
given the branch is still behind when the repair is cancelled. -/
def mootWithoutBase : Block → Bool
  | .branchBehind => true
  | _ => false

/-- `CiRepairSafety.moot_block?`: whether a repair held by `b` is cancelled,
where `superseded` says main has moved past the repair's base. -/
def mootBlock (b : Block) (superseded : Bool) : Bool :=
  mootWithoutBase b || (superseded && waitsOnOwnBase b)

/-- Before: a behind-base repair parks even though only a rebase -- which
preempts it -- could ever clear its block. -/
theorem behind_before_parks : ∀ p ∈ phases, cancelsAfter p .branchBehind = false := by decide

/-- Now: a behind-base repair is cancelled whatever its base. -/
theorem moot_cancels_behind : ∀ s ∈ [true, false], mootBlock .branchBehind s = true := by decide

/-- Now: every other block is cancelled exactly as before, on a superseded
base only and only when it waits on that base. -/
theorem moot_keeps_base_blocks :
    ∀ p ∈ phases, ∀ b ∈ blocks, b ≠ .branchBehind → mootBlock b true = cancelsAfter p b := by decide

/-- Now: nothing is cancelled for a base still current, except a behind-base
block. -/
theorem moot_current_base_only_behind : ∀ b ∈ blocks, mootBlock b false = mootWithoutBase b := by decide

/-- Never cancelled: the repair is disabled, its base is unknown, or it is a
duplicate of another repair -- each of which can still clear. -/
theorem moot_never_clearable :
    ∀ s ∈ [true, false], mootBlock .disabled s = false ∧ mootBlock .baseShaUnknown s = false ∧ mootBlock .duplicate s = false := by decide

end SupersededCiRepair
end SyrusModel
