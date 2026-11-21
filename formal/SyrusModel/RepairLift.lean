/-!
# DOC-44 Phase 3: a landed main-branch repair lifts the pause only for the commit it proved

When a main-branch repair Job closes as merged, `MainHealthChangedService#
repair_landed!` records main as healthy and calls `recovered!`, which lifts
the strict-policy landing pause and releases held work. The evidence behind
that is the repair's own landing validation, which covers its merge result
(`job.landed_sha`) and nothing after it.

It recorded health for the *live* default-branch head instead. If anything
reached main after the repair (an isolation-policy landing, a manual push),
that ungraded commit was declared healthy and the pause lifted
(`later_commit_declared_healthy`). DOC-44: "Stale or inconclusive evidence
cannot be treated as current proof of health"; "A successful repair lifts the
correct pause".

After the fix, a live head that differs from the landed commit is graded
(`PollMainBranchHealthJob`) instead; the pause stays until that grade says so.
A repair with no recorded landed SHA keeps the old behaviour.
-/

namespace SyrusModel
namespace RepairLift

inductive Action where
  /-- Declare `sha` healthy and lift the pause. -/
  | declareHealthy (sha : Nat)
  /-- Keep the pause and grade the live head. -/
  | grade
  deriving DecidableEq, Repr

structure Input where
  /-- The repair's merge result (`job.landed_sha`), if recorded. -/
  landed : Option Nat
  /-- The live default-branch head, if it could be read. -/
  live : Option Nat
  /-- `job.head_sha` / last checked SHA fallback. -/
  fallback : Nat
  deriving DecidableEq, Repr

def before (i : Input) : Action := .declareHealthy (i.live.getD i.fallback)

def after (i : Input) : Action :=
  match i.landed, i.live with
  | some l, some v => if v == l then .declareHealthy v else .grade
  | _, _ => before i

/-- The commit a declaration is justified for: the landed one, when known. -/
def justified (i : Input) (sha : Nat) : Prop := ∀ l, i.landed = some l → sha = l

theorem later_commit_declared_healthy :
    before ⟨some 1, some 2, 0⟩ = .declareHealthy 2 ∧ ¬ justified ⟨some 1, some 2, 0⟩ 2 := by
  refine ⟨rfl, fun h => ?_⟩
  exact absurd (h 1 rfl) (by decide)

/-- With a known landed commit and a readable head, only that commit is ever
    declared healthy. -/
theorem after_declares_only_landed (i : Input) (sha : Nat) (hv : i.live.isSome)
    (h : after i = .declareHealthy sha) : justified i sha := by
  intro l hl
  obtain ⟨landed, live, fb⟩ := i
  simp only at hl hv
  subst hl
  cases live with
  | none => simp at hv
  | some v =>
    simp only [after] at h
    by_cases hc : v = l
    · subst hc; simp at h; exact h.symm
    · simp [hc] at h

/-- The fix only withholds declarations: whatever it declares, the old code
    declared too. -/
theorem after_declare_was_before (i : Input) (sha : Nat) (h : after i = .declareHealthy sha) :
    before i = .declareHealthy sha := by
  obtain ⟨landed, live, fb⟩ := i
  cases landed <;> cases live <;> simp_all [after, before]
  rename_i l v
  by_cases hc : v = l
  · subst hc; simp_all
  · simp_all

end RepairLift
end SyrusModel
