/-!
# Verifying merge-train members after the integration branch is rebased

`merge_train_build` records each member's integrated commits (LandedCommit).
`merge_train_rebase` later replays the whole integration branch onto a moved
base: every commit gets a new SHA, and its patch is unchanged (a clean rebase).
The land step verified a member by asking whether its *recorded* SHA is an
ancestor of what landed -- which, after a rebase, it never is. Every member of
a rebased train was marked failed and its landing failed, until the reconciler
closed it a minute later (12 trains in a week, up to 7 members each).

The model: a commit is a SHA and a patch; an integration is a list of commits.
-/

namespace SyrusModel
namespace RebasedMembers

structure Commit where
  sha : Nat
  patch : Nat
  deriving DecidableEq, Repr

/-- A clean rebase: new SHAs (offset), same patches. -/
def rebase (offset : Nat) (cs : List Commit) : List Commit :=
  cs.map fun c => { c with sha := c.sha + offset }

/-- Before: landed iff the recorded SHA is in the integration. -/
def landedBefore (recorded : Commit) (integration : List Commit) : Bool :=
  integration.any (·.sha == recorded.sha)

/-- After: also landed if a commit with the recorded commit's patch is there. -/
def landedAfter (recorded : Commit) (integration : List Commit) : Bool :=
  landedBefore recorded integration || integration.any (·.patch == recorded.patch)

/-- Before: a member that genuinely landed through a rebased train is rejected. -/
theorem before_rejects_rebased :
    let c : Commit := ⟨1, 7⟩
    landedBefore c (rebase 100 [c]) = false := by decide

/-- After: any member whose commit was in the train is still recognised once the
    train is rebased (offset > 0 so every SHA changes). -/
theorem after_accepts_rebased (c : Commit) (cs : List Commit) (offset : Nat)
    (h : c ∈ cs) : landedAfter c (rebase offset cs) = true := by
  unfold landedAfter
  apply Bool.or_eq_true_iff.mpr
  right
  apply List.any_eq_true.mpr
  refine ⟨{ c with sha := c.sha + offset }, ?_, by simp⟩
  exact List.mem_map.mpr ⟨c, h, rfl⟩

/-- And it never accepts a member none of whose patch reached the integration
    (unless the very SHA is there). -/
theorem after_sound (c : Commit) (integration : List Commit)
    (hsha : ∀ d ∈ integration, d.sha ≠ c.sha) (hpatch : ∀ d ∈ integration, d.patch ≠ c.patch) :
    landedAfter c integration = false := by
  unfold landedAfter landedBefore
  simp only [Bool.or_eq_false_iff, List.any_eq_false, beq_iff_eq]
  exact ⟨hsha, hpatch⟩

end RebasedMembers
end SyrusModel
