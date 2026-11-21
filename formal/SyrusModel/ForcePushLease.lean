/-!
# DOC-44 Phase 3: a force push never overwrites an unobserved remote update

DOC-44: "Force-with-lease cannot overwrite an unobserved remote update."

Every Syrus force push names the remote by URL and uses one of three lease
forms. Their git semantics are pinned against real git by
`spec/lib/git_force_with_lease_semantics_spec.rb`:

* `explicit sha` (`refs/heads/b:<sha>`): accepted only while the remote
  branch is exactly `sha`;
* `absent` (`refs/heads/b:`): accepted only while the branch does not exist;
* `bare` against a URL: no remote-tracking ref to compare with, so git
  accepts only while the branch does not exist ("stale info" otherwise).

The SHA in `explicit` is always one Syrus observed (`ls-remote`, or the
branch tip right after fetching, before any agent ran):
`Steps::ForcePush`, `AutoRebase`, `Steps::StackForcePush` (`pre_sha` from
`StackAgentRebase`), `Steps::MergeTrainLand#push_lease_args`,
`Steps::PrOpen`, `Steps::ExternalPrMerge`, `BranchDivergenceRecovery`.

Proved: an accepted push replaced exactly the state Syrus observed
(`accepted_replaces_observed`), so any update made after the observation
makes the push fail (`unobserved_update_rejects`). No bug found. The one
plain `--force` (`Steps::MergeTrainBuild`) publishes a train's freshly built
integration branch, which only that train writes.
-/

namespace SyrusModel
namespace ForcePushLease

/-- The remote branch: `none` when it does not exist. -/
abbrev Remote := Option Nat

inductive Lease where
  | explicit (sha : Nat)
  | absent
  | bare
  deriving DecidableEq, Repr

/-- What the lease form expects the remote to be. -/
def Lease.expects : Lease → Remote
  | .explicit sha => some sha
  | .absent => none
  | .bare => none

/-- git's decision (pinned by the boundary spec). -/
def accepts (l : Lease) (remote : Remote) : Bool := remote == l.expects

theorem accepted_replaces_observed (l : Lease) (remote : Remote) (h : accepts l remote = true) :
    remote = l.expects := by
  simpa [accepts] using h

/-- Syrus observed `observed` and built the lease from it; someone else then
    changed the remote. The push is refused. -/
theorem unobserved_update_rejects (observed current : Remote) (h : current ≠ observed) :
    accepts (match observed with | some s => .explicit s | none => .absent) current = false := by
  cases observed with
  | none =>
    cases current with
    | none => exact absurd rfl h
    | some c => rfl
  | some s => simp_all [accepts, Lease.expects]

/-- The bare form never overwrites an existing branch. -/
theorem bare_never_overwrites (sha : Nat) : accepts .bare (some sha) = false := rfl

end ForcePushLease
end SyrusModel
