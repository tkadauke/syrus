/-!
# DOC-44 Phase 3: a landing repair keeps a grader's pass only if nothing it reads changed

After a code-changing landing repair, `Steps::GraderFanout#
partition_evidence_driven_repair_graders` keeps an earlier pass of a grader
instead of rerunning it when the repair could not have reached it. That
retained pass lands in the validation manifest as a `carried_forward` result,
which the landing gate accepts on its fingerprints (`ValidationGate.
reused_not_sha_checked`), so this decision is what binds it to the commit
being landed.

The decision reads two things:

* `repair_affects_target?`: the repair Run's own diff (`step_agent_diff`)
  against the target's source scope, or, for a repo-wide target, against its
  dependencies' scopes;
* `reusable_repair_fingerprints?`: command and environment fingerprints, and
  the input fingerprint (the hash of every file in the target's and its
  dependencies' scopes) only when the target *itself* has a scope.

The repair's diff is not everything that changed in its iteration: `format`
and `generate` run after it and commit their own changes. For a repo-wide
target with a scoped dependency, such a change was invisible to both checks,
and the earlier pass was kept (`kept_after_generated_change`).

A repo-wide target with *no* scoped dependency is kept after any narrow
repair by design (`.syrus.yml` docs, `metadata.always_rerun`): its input
fingerprint is the whole repository, so comparing it would rerun it after
every repair. The model states that as the boundary of the property.

Files are numbers; a scope is a list of files.
-/

namespace SyrusModel
namespace RepairReuse

def hits (scope files : List Nat) : Bool := files.any (scope.contains ·)

structure Case where
  /-- The target's own source scope (empty: repo-wide). -/
  own : List Nat
  /-- The union of its dependencies' source scopes. -/
  deps : List Nat
  /-- Files in the repair Run's own diff. -/
  agent : List Nat
  /-- Files changed by later steps of the iteration (format, generate). -/
  post : List Nat
  deriving DecidableEq, Repr

/-- The scope the input fingerprint hashes, when there is one. -/
def Case.scope (c : Case) : List Nat := c.own ++ c.deps

/-- Whether the input fingerprint changed: some changed file is in its scope.
    (Idealised: a hash differs exactly when a hashed file changed.) -/
def inputChanged (c : Case) : Bool := hits c.scope (c.agent ++ c.post)

/-- `repair_affects_target?` on the repair's own diff. -/
def repairAffects (c : Case) : Bool :=
  if c.own.isEmpty then hits c.deps c.agent else hits c.scope c.agent

/-- Before: input fingerprint compared only for a target with its own scope. -/
def keepBefore (c : Case) : Bool :=
  !repairAffects c && (c.own.isEmpty || !inputChanged c)

/-- After: compared whenever the closure has any scope (`scoped_closure?`). -/
def keepAfter (c : Case) : Bool :=
  !repairAffects c && (c.scope.isEmpty || !inputChanged c)

/-- The counterexample: a repo-wide target depending on scope `[1]`; the repair
    changed file 2, `generate` then changed file 1. The pass was kept. -/
theorem kept_after_generated_change :
    keepBefore ⟨[], [1], [2], [1]⟩ = true ∧ inputChanged ⟨[], [1], [2], [1]⟩ = true := by decide

theorem hits_false {scope files : List Nat} (h : hits scope files = false) :
    ∀ f ∈ files, f ∉ scope := by
  intro f hf hs
  have : hits scope files = true := List.any_eq_true.mpr ⟨f, hf, by simpa using hs⟩
  rw [h] at this; exact Bool.noConfusion this

/-- After the fix, a kept pass means no file the target reads changed in the
    whole iteration, whoever changed it -- whenever the target reads a scoped
    set of files at all. -/
theorem keepAfter_nothing_read_changed (c : Case) (h : keepAfter c = true) (hs : c.scope ≠ []) :
    ∀ f ∈ c.agent ++ c.post, f ∉ c.scope := by
  simp only [keepAfter, Bool.and_eq_true, Bool.or_eq_true, Bool.not_eq_true'] at h
  obtain ⟨_, h2⟩ := h
  rcases h2 with he | hi
  · exact absurd (List.isEmpty_iff.mp he) hs
  · exact hits_false hi

/-- The fix only ever reruns more: it never keeps a pass the old rule reran. -/
theorem keepAfter_implies_keepBefore (c : Case) (h : keepAfter c = true) : keepBefore c = true := by
  simp only [keepAfter, keepBefore, Case.scope, Bool.and_eq_true, Bool.or_eq_true, Bool.not_eq_true'] at h ⊢
  obtain ⟨h1, h2⟩ := h
  refine ⟨h1, ?_⟩
  rcases h2 with he | hi
  · left; simp [List.isEmpty_iff] at he ⊢; exact he.1
  · right; exact hi

/-- And it changes the decision only for a repo-wide target whose dependencies
    have a scope -- the gap. Scoped targets and fully repo-wide targets are
    decided as before. -/
theorem keep_differs_only_for_scoped_dependencies (c : Case) (h : keepAfter c ≠ keepBefore c) :
    c.own = [] ∧ c.deps ≠ [] := by
  cases ho : c.own with
  | cons a l =>
    exfalso; apply h
    simp [keepAfter, keepBefore, Case.scope, ho]
  | nil =>
    refine ⟨rfl, fun hd => h ?_⟩
    simp [keepAfter, keepBefore, Case.scope, ho, hd]

end RepairReuse
end SyrusModel
