/-!
# Workflow artifacts: no lost updates

A Workflow's artifacts are a key → value map stored one row per key
(`workflow_artifact_values`). Writers either use `set_artifact!` (per key, under
a row lock) or assign the whole bag on an instance and save it. The bag path is
the risky one: the instance loaded the map at some earlier time, and other
writers may have changed keys since.

We model one stale writer racing any number of concurrent per-key writes:

* `loaded` — what the instance read,
* `db` — the store when the instance saves (concurrent writes already applied),
* `staged` — the bag the caller assigned.

`saveWhole` is the old `persist_assigned_external_artifacts`: write every staged
key. `saveDelta` is the fix: write only keys whose staged value differs from
`loaded`. The same shape described `WorkflowCancellation#cancel!`, which merged
its whole pre-lock snapshot over the freshly reloaded map.
-/

namespace SyrusModel
namespace Artifacts

variable {K V : Type} [DecidableEq V]

abbrev Store (K V : Type) := K → Option V

/-- Keys the caller changed relative to what it loaded. -/
def changed (loaded staged : Store K V) (k : K) : Prop := staged k ≠ loaded k

/-- Old behavior: every staged key is written back. (Absent staged keys are left
    alone — deletions are handled separately in Ruby and are not modelled.) -/
def saveWhole (staged db : Store K V) : Store K V :=
  fun k => match staged k with
    | some v => some v
    | none => db k

/-- Fixed behavior: only keys the caller changed are written. -/
def saveDelta (loaded staged db : Store K V) : Store K V :=
  fun k => if staged k ≠ loaded k ∧ (staged k).isSome then staged k else db k

/-- **No lost update.** A key the caller did not change keeps whatever a
    concurrent writer stored. -/
theorem delta_preserves_concurrent (loaded staged db : Store K V) (k : K)
    (h : ¬ changed loaded staged k) : saveDelta loaded staged db k = db k := by
  unfold changed at h
  simp [saveDelta, h]

/-- **The caller's own edits land.** -/
theorem delta_applies_changes (loaded staged db : Store K V) (k : K) (v : V)
    (hs : staged k = some v) (hc : changed loaded staged k) : saveDelta loaded staged db k = some v := by
  unfold changed at hc
  rw [hs] at hc
  simp [saveDelta, hs, hc]

/-- When nobody wrote concurrently, the fix saves exactly what the old code did. -/
theorem delta_eq_whole_without_race (loaded staged : Store K V) :
    ∀ k, (staged k).isSome → saveDelta loaded staged loaded k = saveWhole staged loaded k := by
  intro k hk
  simp only [saveDelta, saveWhole]
  cases hs : staged k with
  | none => simp [hs] at hk
  | some v =>
    by_cases hc : some v = loaded k
    · simp [hc]
    · simp [hc]

/-- The old behavior reverts a concurrent write: the caller loaded `"old"`,
    another writer stored `"new"`, the caller saved its bag unchanged for that key. -/
theorem whole_loses_update :
    let loaded : Store Nat String := fun k => if k = 0 then some "old" else none
    let db : Store Nat String := fun k => if k = 0 then some "new" else none
    let staged : Store Nat String := fun k => if k = 0 then some "old" else if k = 1 then some "title" else none
    saveWhole staged db 0 = some "old" ∧ saveDelta loaded staged db 0 = some "new" ∧
      saveDelta loaded staged db 1 = some "title" := by
  decide

end Artifacts
end SyrusModel
