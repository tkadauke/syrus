/-!
# A merge train marks a member merged only with evidence

`Steps::MergeTrainLand#reconcile_members!` decides, per member, whether its
work reached the landed integration commit. Evidence, in order: the member's
last recorded `LandedCommit` is an ancestor of the integration SHA; or git
cannot tell (object missing locally) and the commit was recorded by this
Workflow's own build; or the member branch is patch-equivalent to the base.

The check ran only `if integration_sha.present?`: with no integration SHA every
member was marked merged and its Job closed with no evidence at all.
-/

namespace SyrusModel
namespace TrainEvidence

inductive Anc where | ancestor | notAncestor | indeterminate deriving DecidableEq, Repr

structure Member where
  /-- A LandedCommit row exists for the member. -/
  recorded : Bool
  anc : Anc
  /-- The row was written by this Workflow's build. -/
  recentBuild : Bool
  patchEquivalent : Bool
  deriving DecidableEq, Repr

/-- `member_landed?` -/
def landed (m : Member) : Bool :=
  m.recorded &&
    match m.anc with
    | .ancestor => true
    | .notAncestor => m.patchEquivalent
    | .indeterminate => m.recentBuild || m.patchEquivalent

/-- Some piece of evidence supports the member having landed. -/
def evidence (m : Member) : Bool :=
  m.recorded && (m.anc = .ancestor || m.patchEquivalent || (m.anc = .indeterminate && m.recentBuild))

/-- Old decision: skip the check entirely without an integration SHA. -/
def mergedBefore (sha : Bool) (m : Member) : Bool := !sha || landed m

/-- Fixed decision: no integration SHA, no evidence. -/
def mergedAfter (sha : Bool) (m : Member) : Bool := sha && landed m

def allMembers : List Member :=
  [true, false].flatMap fun r => [Anc.ancestor, .notAncestor, .indeterminate].flatMap fun a =>
    [true, false].flatMap fun b => [true, false].map fun p => ⟨r, a, b, p⟩

theorem before_merges_without_evidence :
    mergedBefore false ⟨false, .notAncestor, false, false⟩ = true := by decide

/-- Fixed: marked merged ⇒ there is an integration SHA and evidence. -/
theorem after_merged_has_evidence :
    allMembers.all (fun m => [true, false].all fun sha => !mergedAfter sha m || (sha && evidence m)) = true := by
  decide

end TrainEvidence
end SyrusModel
