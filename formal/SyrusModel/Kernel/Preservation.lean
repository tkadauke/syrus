import SyrusModel.Kernel.Reconcile

/-!
# DOC-44 Phase 1 kernel: validity preservation and repair scoping

* `reconcile_valid`: reconciling a valid world yields a valid world (DOC-44,
  "Reconciliation preserves valid worlds").
* Scoping (DOC-44, "A scoped repair cannot mutate unrelated Jobs, WorkUnits,
  or locks"): a Run is changed only if its Workflow or Step has finished, a
  Step only if its Workflow has finished, a
  unit only if its own Workflow has a terminal outcome, and a lock is dropped
  only if its holder is not active after the unit sync. Everything else is
  left exactly as it was.
-/

namespace SyrusModel
namespace Kernel
namespace World

theorem fixRun_id (w : World) (r : Run) : (w.fixRun r).id = r.id := by
  unfold fixRun; split <;> rfl

theorem fixUnit_intent (w : World) (u : Unit) : (w.fixUnit u).intent = u.intent := by
  unfold fixUnit; split <;> rfl

theorem map_ids_eq {α : Type} (f : α → α) (ids : α → Id) (h : ∀ x, ids (f x) = ids x) (xs : List α) :
    (xs.map f).map ids = xs.map ids := by
  rw [List.map_map]; congr 1; funext x; exact h x

/-! ## Validity preservation -/

theorem reconcile_valid {w : World} (hv : w.Valid) : w.reconcile.Valid where
  intentsUnique := hv.intentsUnique
  unitsUnique := by
    show ((w.units.map w.fixUnit).map Unit.id).Nodup
    rw [map_ids_eq _ _ (fixUnit_id w)]; exact hv.unitsUnique
  workflowsUnique := hv.workflowsUnique
  stepsUnique := by
    show ((w.steps.map w.fixStep).map Step.id).Nodup
    rw [map_ids_eq _ _ (fixStep_id w)]; exact hv.stepsUnique
  runsUnique := by
    show ((w.runs.map w.fixRun).map Run.id).Nodup
    rw [map_ids_eq _ _ (fixRun_id w)]; exact hv.runsUnique
  lockKeysUnique := by
    show ((w.locks.filter w.lockKeep).map Lock.key).Nodup
    exact hv.lockKeysUnique.sublist ((List.filter_sublist (l := w.locks)).map _)
  unitIntent := by
    intro u hu
    obtain ⟨u0, hu0, rfl⟩ := List.mem_map.mp hu
    obtain ⟨i, hi, he⟩ := hv.unitIntent u0 hu0
    exact ⟨i, hi, by rw [he, fixUnit_intent]⟩
  unitWorkflow := by
    intro u hu wf hwf
    obtain ⟨u0, hu0, rfl⟩ := List.mem_map.mp hu
    rw [fixUnit_workflow] at hwf
    exact hv.unitWorkflow u0 hu0 wf hwf
  stepWorkflow := by
    intro s hs
    obtain ⟨s0, hs0, rfl⟩ := List.mem_map.mp hs
    rw [fixStep_workflow]
    exact hv.stepWorkflow s0 hs0
  runStep := by
    intro r hr
    obtain ⟨r0, hr0, rfl⟩ := List.mem_map.mp hr
    obtain ⟨s, hs, he⟩ := hv.runStep r0 hr0
    refine ⟨w.fixStep s, List.mem_map.mpr ⟨s, hs, rfl⟩, ?_⟩
    rw [fixStep_id, he, fixRun_step]
  lockUnit := by
    intro l hl
    obtain ⟨u, hu, he⟩ := hv.lockUnit l (List.mem_filter.mp hl).1
    exact ⟨w.fixUnit u, List.mem_map.mpr ⟨u, hu, rfl⟩, by rw [fixUnit_id, he]⟩

/-! ## Scoping -/

/-- A Run is changed only if the Workflow above it or its own Step has
    finished, and then only to an inactive state. -/
theorem fixRun_changed_only_under_terminal (w : World) (r : Run) (h : w.fixRun r ≠ r) :
    (w.runWorkflowTerminal r = true ∨ w.runStepTerminal r = true) ∧ (w.fixRun r).state.active = false := by
  by_cases hc : w.runStale r = true
  · refine ⟨?_, ?_⟩
    · unfold runStale at hc; simp_all
    · rw [fixRun_pos w hc]; exact runTarget_inactive w r
  · exact absurd (fixRun_neg w hc) h

/-- A Step is changed only if its Workflow has finished. -/
theorem fixStep_changed_only_under_terminal (w : World) (s : Step) (h : w.fixStep s ≠ s) :
    w.stepWorkflowTerminal s = true := by
  by_cases hc : w.stepStale s = true
  · exact stepStale_terminal w s hc
  · exact absurd (fixStep_neg w hc) h

/-- A unit is changed only to the outcome of its own Workflow, and only while
    it is active. -/
theorem fixUnit_changed_only_from_own_workflow (w : World) (u : Unit) (h : w.fixUnit u ≠ u) :
    u.state.active = true ∧ ∃ wf st o, u.workflow = some wf ∧ w.workflowState? wf = some st ∧
      unitOutcome st = some o ∧ w.fixUnit u = { u with state := o } := by
  unfold fixUnit at h ⊢
  cases ht : w.unitTarget u with
  | none => simp [ht] at h
  | some o =>
    simp only [ht] at h ⊢
    unfold unitTarget at ht
    by_cases ha : u.state.active = true
    · simp only [ha, if_true] at ht
      cases hwf : u.workflow with
      | none => simp [hwf] at ht
      | some wf =>
        simp only [hwf, Option.bind_eq_some_iff] at ht
        obtain ⟨st, hst, ho⟩ := ht
        exact ⟨ha, wf, st, o, rfl, hst, ho, rfl⟩
    · simp [ha] at ht

/-- A lock is dropped only if its holder is not active after the unit sync. -/
theorem lock_dropped_only_if_holder_inactive (w : World) (l : Lock) (hl : l ∈ w.locks)
    (hd : l ∉ w.reconcile.locks) : w.lockKeep l = false := by
  cases hk : w.lockKeep l with
  | false => rfl
  | true => exact absurd (List.mem_filter.mpr ⟨hl, hk⟩) hd

/-- Reconciliation never creates records: every reconciled Run, Step, unit or
    lock comes from one in the original world with the same id or key. -/
theorem reconcile_no_new_runs (w : World) (r : Run) (hr : r ∈ w.reconcile.runs) :
    ∃ r0 ∈ w.runs, r0.id = r.id := by
  obtain ⟨r0, hr0, rfl⟩ := List.mem_map.mp hr
  exact ⟨r0, hr0, (fixRun_id w r0).symm⟩

theorem reconcile_locks_sub (w : World) : w.reconcile.locks ⊆ w.locks :=
  fun _ hl => (List.mem_filter.mp hl).1

end World
end Kernel
end SyrusModel
