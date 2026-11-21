import SyrusModel.Proofs

/-!
# Lock safety for running units

Under the assumption that each Workflow has at most one WorkUnit
(`UniqueRuntime`), every lifecycle operation preserves:

> a running unit that enforces lock conflicts holds every key it needs,

and therefore two distinct running, enforcing units never need the same key.

`Examples.shared` in `Counterexamples.lean` shows the assumption is necessary:
with two units on one Workflow, the "same runtime owner" skip in
`ensure_active_locks!` lets the key escape to an unrelated unit.
-/

namespace SyrusModel
namespace World

variable {nI nU nK : Nat} {w : World nI nU nK}

/-- The strong form: a running, enforcing unit is itself the active holder. -/
def HoldsOwnLocks (w : World nI nU nK) : Prop :=
  ∀ u k, (w.unit u).state = .running → (w.unit u).enforced = true → w.needsKey u k = true →
    w.holder k = some u

theorem sameOwner_eq (hu : w.UniqueRuntime) {a b : Fin nU} (h : w.sameOwner a b = true) : a = b := by
  unfold sameOwner at h
  simp only [Bool.or_eq_true, beq_iff_eq, Bool.and_eq_true] at h
  rcases h with h | ⟨hs, he⟩
  · exact h
  · exact hu a b hs he

/-- Under `UniqueRuntime`, the Ruby-shaped property and the strong form agree. -/
theorem runningHoldsLocks_iff (hu : w.UniqueRuntime) : w.RunningHoldsLocks ↔ w.HoldsOwnLocks := by
  constructor
  · intro h u k hr he hn
    obtain ⟨o, ho, hs⟩ := h u k hr he hn
    rw [ho, sameOwner_eq hu hs]
  · intro h u k hr he hn
    refine ⟨u, h u k hr he hn, ?_⟩
    simp [sameOwner]

/-- The safety statement lock mutual exclusion exists for. -/
theorem mutual_exclusion (h : w.HoldsOwnLocks) {u v : Fin nU} {k : Fin nK}
    (hu : (w.unit u).state = .running) (hue : (w.unit u).enforced = true) (hun : w.needsKey u k = true)
    (hv : (w.unit v).state = .running) (hve : (w.unit v).enforced = true) (hvn : w.needsKey v k = true) :
    u = v := by
  have h1 := h u k hu hue hun
  have h2 := h v k hv hve hvn
  rw [h1] at h2
  exact Option.some.inj h2

/-! ## A frame condition every operation satisfies -/

/-- What an operation on unit `u` may change. -/
structure Frame (w w' : World nI nU nK) (u : Fin nU) : Prop where
  workflow : ∀ v, (w'.unit v).workflow = (w.unit v).workflow
  needs : ∀ v, (w'.unit v).needs = (w.unit v).needs
  enforced : ∀ v, (w'.unit v).enforced = (w.unit v).enforced
  others : ∀ v, v ≠ u → (w'.unit v).state = (w.unit v).state
  keep : ∀ k v, v ≠ u → w.holder k = some v → w'.holder k = some v
  self : (w'.unit u).state = .running → (w'.unit u).enforced = true →
    ∀ k, w'.needsKey u k = true → w'.holder k = some u

theorem Frame.needsKey {w' : World nI nU nK} {u : Fin nU} (f : Frame w w' u) (v k) :
    w'.needsKey v k = w.needsKey v k := by
  simp [World.needsKey, f.workflow v, f.needs v]

theorem Frame.holdsOwnLocks {w' : World nI nU nK} {u : Fin nU} (f : Frame w w' u)
    (h : w.HoldsOwnLocks) : w'.HoldsOwnLocks := by
  intro v k hr he hn
  by_cases hv : v = u
  · subst hv; exact f.self hr he k hn
  · rw [f.others v hv] at hr
    rw [f.enforced v] at he
    rw [f.needsKey] at hn
    exact f.keep k v hv (h v k hr he hn)

theorem Frame.uniqueRuntime {w' : World nI nU nK} {u : Fin nU} (f : Frame w w' u)
    (h : w.UniqueRuntime) : w'.UniqueRuntime := by
  intro a b ha hab
  rw [f.workflow a] at ha hab
  rw [f.workflow b] at hab
  exact h a b ha hab

/-- Shared shape: `u` ends in a non-running state, only `u`'s fields change, and
    only `u`'s locks may be released. -/
theorem frame_of_not_running {w' : World nI nU nK} {u : Fin nU}
    (hunit : ∀ v, v ≠ u → w'.unit v = w.unit v)
    (hwf : (w'.unit u).workflow = (w.unit u).workflow)
    (hneeds : (w'.unit u).needs = (w.unit u).needs)
    (henf : (w'.unit u).enforced = (w.unit u).enforced)
    (hkeep : ∀ k v, v ≠ u → w.holder k = some v → w'.holder k = some v)
    (hnr : (w'.unit u).state ≠ .running) : Frame w w' u where
  workflow v := by by_cases hv : v = u; (subst hv; exact hwf); rw [hunit v hv]
  needs v := by by_cases hv : v = u; (subst hv; exact hneeds); rw [hunit v hv]
  enforced v := by by_cases hv : v = u; (subst hv; exact henf); rw [hunit v hv]
  others v hv := by rw [hunit v hv]
  keep := hkeep
  self hr := absurd hr hnr

theorem releaseWhere_keep {u : Fin nU} {p} (k : Fin nK) (v : Fin nU) (hv : v ≠ u)
    (h : w.holder k = some v) : (w.releaseWhere u p).holder k = some v := by
  simp only [releaseWhere_holder, h, Option.some.injEq, hv, false_and, ite_false]

theorem block_frame (u : Fin nU) (r : BlockReason) : Frame w (w.block u r) u := by
  cases r <;>
  · apply frame_of_not_running
    · intro v hv; simp [block, reactivate_unit, hv]
    · simp [block, reactivate_unit]
    · simp [block, reactivate_unit]
    · simp [block, reactivate_unit]
    · intro k v hv h
      simp only [block, setState_holder, reactivate_holder]
      first | exact releaseWhere_keep (w := (w.reactivate u).setState u .blocked) k v hv
                (by simp [reactivate_holder, h]) | exact h
    · simp [block, reactivate_unit]

theorem unblock_frame (u : Fin nU) : Frame w (w.unblock u) u := by
  apply frame_of_not_running
  · intro v hv; simp [unblock, reactivate_unit, hv]
  · simp [unblock, reactivate_unit]
  · simp [unblock, reactivate_unit]
  · simp [unblock, reactivate_unit]
  · intro k v _ h; simp [unblock, reactivate_holder, h]
  · simp [unblock, reactivate_unit]

theorem markTerminal_frame (u : Fin nU) (s : UnitState) {w' : World nI nU nK}
    (hrun : w.markTerminal u s = some w') : Frame w w' u := by
  unfold markTerminal at hrun
  split at hrun
  · rename_i hs
    simp only [Option.some.injEq] at hrun; subst hrun
    apply frame_of_not_running
    · intro v hv; simp [sync_unit, hv]
    · simp [sync_unit]
    · simp [sync_unit]
    · simp [sync_unit]
    · intro k v hv h
      rw [sync_holder]; simp only [releaseAll_holder, setState_holder, h, Option.some.injEq, hv, ite_false]
    · simp only [sync_unit, releaseAll_unit, setState_unit, ite_true]
      intro he; subst he; simp [UnitState.terminal] at hs
  · simp at hrun

theorem preempt_frame (u : Fin nU) (r : Reason) : Frame w (w.preempt u r) u := by
  unfold preempt
  split
  · rename_i hc
    apply frame_of_not_running
    · intro v hv; simp [sync_unit, hv]
    · simp [sync_unit]
    · simp [sync_unit]
    · simp [sync_unit]
    · intro k v _ h; simp [sync_holder, h]
    · simp [sync_unit, hc]
  · split
    · apply frame_of_not_running
      · intro v hv; simp [sync_unit, hv]
      · simp [sync_unit]
      · simp [sync_unit]
      · simp [sync_unit]
      · intro k v hv h
        rw [sync_holder]; simp only [releaseAll_holder, setUnit_holder, h, Option.some.injEq, hv, ite_false]
      · simp [sync_unit]
    · rename_i hnc hna
      apply frame_of_not_running (fun _ _ => rfl) rfl rfl rfl (fun _ _ _ h => h)
      intro hr; simp [hr, UnitState.active, UnitState.terminal] at hna

/-- The interesting case: `mark_running!` either raises or leaves `u` holding
    every key it needs. This is where `UniqueRuntime` is used. -/
theorem markRunning_frame (hu : w.UniqueRuntime) (u : Fin nU) {w' : World nI nU nK}
    (hrun : w.markRunning u = some w') : Frame w w' u := by
  unfold markRunning ensureLocks at hrun
  split at hrun
  · simp at hrun
  · rename_i hnc
    simp only [Option.map_some, Option.some.injEq] at hrun
    subst hrun
    have hru : (w.reactivate u).unit = w.unit := reactivate_unit u
    have hrh : (w.reactivate u).holder = w.holder := reactivate_holder u
    have hnk : ∀ k, (w.reactivate u).needsKey u k = w.needsKey u k := by
      intro k; simp [World.needsKey, hru]
    refine
      { workflow := ?_, needs := ?_, enforced := ?_, others := ?_, keep := ?_, self := ?_ }
    · intro v; by_cases hv : v = u <;> simp [hru, hv]
    · intro v; by_cases hv : v = u <;> simp [hru, hv]
    · intro v; by_cases hv : v = u <;> simp [hru, hv]
    · intro v hv; simp [hru, hv]
    · intro k v _ h
      simp only [setState_holder, hrh, h, reduceCtorEq, and_false, ite_false]
    · intro _ henf k hn
      simp only [setState_holder]
      have hn' : w.needsKey u k = true := by
        rw [← hnk]; simpa [World.needsKey, hru] using hn
      cases hk : w.holder k with
      | none => simp [hrh, hk, hnk, hn']
      | some o =>
        have hno := fun h => hnc ⟨k, h⟩
        simp only [World.conflict, hrh, hk, hnk, hn', Bool.true_and] at hno
        have henf' : (w.unit u).enforced = true := by simpa [hru] using henf
        have hso : (w.reactivate u).sameOwner u o = true := by
          cases hs : (w.reactivate u).sameOwner u o
          · simp [hru, henf', hs] at hno
          · rfl
        have hso' : w.sameOwner u o = true := by simpa [World.sameOwner, hru] using hso
        have := sameOwner_eq hu hso'
        subst this
        simp [hrh, hk]

/-! ## The headline theorem -/

/-- Every ownership-layer lifecycle step preserves `UniqueRuntime ∧ HoldsOwnLocks`. -/
inductive Step (w : World nI nU nK) : World nI nU nK → Prop
  | block (u r) : Step w (w.block u r)
  | unblock (u) : Step w (w.unblock u)
  | markRunning (u) {w'} : w.markRunning u = some w' → Step w w'
  | markTerminal (u s) {w'} : w.markTerminal u s = some w' → Step w w'
  | preempt (u r) : Step w (w.preempt u r)

theorem step_lock_safe {w' : World nI nU nK} (hu : w.UniqueRuntime) (h : w.HoldsOwnLocks)
    (hs : Step w w') : w'.UniqueRuntime ∧ w'.HoldsOwnLocks := by
  have f : ∃ u, Frame w w' u := by
    cases hs with
    | block u r => exact ⟨u, block_frame u r⟩
    | unblock u => exact ⟨u, unblock_frame u⟩
    | markRunning u hr => exact ⟨u, markRunning_frame hu u hr⟩
    | markTerminal u s hr => exact ⟨u, markTerminal_frame u s hr⟩
    | preempt u r => exact ⟨u, preempt_frame u r⟩
  obtain ⟨u, f⟩ := f
  exact ⟨f.uniqueRuntime hu, f.holdsOwnLocks h⟩

/-- Reachable by any finite sequence of lifecycle steps. -/
inductive Reach : World nI nU nK → World nI nU nK → Prop
  | refl (x : World nI nU nK) : Reach x x
  | tail {a b c} : Reach a b → Step b c → Reach a c

/-- ...and so does any finite sequence of them. -/
theorem steps_lock_safe {w w' : World nI nU nK} (hu : w.UniqueRuntime) (h : w.HoldsOwnLocks)
    (hs : Reach w w') : w'.UniqueRuntime ∧ w'.HoldsOwnLocks := by
  induction hs with
  | refl => exact ⟨hu, h⟩
  | tail _ hstep ih => exact step_lock_safe ih.1 ih.2 hstep

end World
end SyrusModel
