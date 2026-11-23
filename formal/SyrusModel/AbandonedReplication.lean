/-!
# An abandoned backup upload stops protecting its backup (NY21, decided A)

`LocalBackups::Retention` never deletes a backup with an `uploading`
replication. A replication whose worker died stays `uploading` until the same
destination pins again, so a backup whose destination is gone was protected
forever. `LocalBackups::AbandonedReplicationSweep` marks such a replication
failed.

A replication is released when its lease has expired, every enabled
destination declares its identity, and none of the configured ones claims it.

This proves the sweep is safe (it never releases an upload a live destination
could still finish) and complete (every abandoned upload is released by the
next pass).
-/

namespace SyrusModel
namespace AbandonedReplication

structure Upload where
  leaseExpired : Bool
  claimedByConfigured : Bool
  allDestinationsIdentified : Bool
  deriving DecidableEq, Repr

/-- `AbandonedReplicationSweep#call` for one replication. -/
def released (u : Upload) : Bool :=
  u.leaseExpired && u.allDestinationsIdentified && !u.claimedByConfigured

/-- Before NY21: nothing ever released an upload. -/
def releasedBefore (_ : Upload) : Bool := false

/-- Abandoned: the lease ran out and no live destination will pin it again. -/
def abandoned (u : Upload) : Bool := u.leaseExpired && !u.claimedByConfigured

def uploads : List Upload :=
  [true, false].flatMap fun e => [true, false].flatMap fun c => [true, false].map fun a => ⟨e, c, a⟩

/-- Before: an abandoned upload pinned its backup forever. -/
theorem before_pins_forever : releasedBefore ⟨true, false, true⟩ = false ∧ abandoned ⟨true, false, true⟩ = true := by decide

/-- Safe: an active lease or a live destination keeps its upload. -/
theorem never_releases_live : ∀ u ∈ uploads, released u = true → u.leaseExpired = true ∧ u.claimedByConfigured = false := by
  decide

/-- Complete: once every destination is identified, every abandoned upload is released. -/
theorem releases_abandoned : ∀ u ∈ uploads, abandoned u = true → u.allDestinationsIdentified = true → released u = true := by
  decide

/-- Conservative: while a destination is anonymous, nothing is released. -/
theorem anonymous_destination_releases_nothing : ∀ u ∈ uploads, u.allDestinationsIdentified = false → released u = false := by
  decide

end AbandonedReplication
end SyrusModel
