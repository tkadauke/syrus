import SyrusModel.Reconciler

/-!
# Theorems over all worlds

Every theorem here quantifies over worlds of any size.
-/

namespace SyrusModel
namespace World

variable {nI nU nK : Nat} {w : World nI nU nK}

/-! ## Frame lemmas for the primitives -/

@[simp] theorem setUnit_unit (u j : Fin nU) (f) :
    (w.setUnit u f).unit j = if j = u then f (w.unit u) else w.unit j := rfl
@[simp] theorem setUnit_intent (u : Fin nU) (f) : (w.setUnit u f).intent = w.intent := rfl
@[simp] theorem setUnit_holder (u : Fin nU) (f) : (w.setUnit u f).holder = w.holder := rfl
@[simp] theorem setUnit_landing (u : Fin nU) (f) : (w.setUnit u f).landing = w.landing := rfl

@[simp] theorem setState_unit (u j : Fin nU) (s) :
    (w.setState u s).unit j = if j = u then { w.unit u with state := s } else w.unit j := rfl
@[simp] theorem setState_intent (u : Fin nU) (s) : (w.setState u s).intent = w.intent := rfl
@[simp] theorem setState_holder (u : Fin nU) (s) : (w.setState u s).holder = w.holder := rfl
@[simp] theorem setState_landing (u : Fin nU) (s) : (w.setState u s).landing = w.landing := rfl

@[simp] theorem setIntent_intent (i j : Fin nI) (s) :
    (w.setIntent i s).intent j = if j = i then s else w.intent j := rfl
@[simp] theorem setIntent_unit (i : Fin nI) (s) : (w.setIntent i s).unit = w.unit := rfl
@[simp] theorem setIntent_holder (i : Fin nI) (s) : (w.setIntent i s).holder = w.holder := rfl
@[simp] theorem setIntent_landing (i : Fin nI) (s) : (w.setIntent i s).landing = w.landing := rfl

@[simp] theorem releaseWhere_holder (u : Fin nU) (p) (k : Fin nK) :
    (w.releaseWhere u p).holder k = if w.holder k = some u ∧ p k = true then none else w.holder k := rfl
@[simp] theorem releaseWhere_unit (u : Fin nU) (p) : (w.releaseWhere u p).unit = w.unit := rfl
@[simp] theorem releaseWhere_intent (u : Fin nU) (p) : (w.releaseWhere u p).intent = w.intent := rfl
@[simp] theorem releaseWhere_landing (u : Fin nU) (p) : (w.releaseWhere u p).landing = w.landing := rfl

@[simp] theorem releaseAll_holder (u : Fin nU) (k : Fin nK) :
    (w.releaseAll u).holder k = if w.holder k = some u then none else w.holder k := by
  simp [releaseAll]
@[simp] theorem releaseAll_unit (u : Fin nU) : (w.releaseAll u).unit = w.unit := rfl
@[simp] theorem releaseAll_intent (u : Fin nU) : (w.releaseAll u).intent = w.intent := rfl

theorem releaseWhere_sub {u : Fin nU} {p} {k : Fin nK} {v : Fin nU}
    (h : (w.releaseWhere u p).holder k = some v) : w.holder k = some v := by
  simp only [releaseWhere_holder] at h
  split at h
  · cases h
  · exact h

theorem reactivate_unit (u : Fin nU) : (w.reactivate u).unit = w.unit := by
  unfold reactivate; split <;> rfl
theorem reactivate_holder (u : Fin nU) : (w.reactivate u).holder = w.holder := by
  unfold reactivate; split <;> rfl
theorem reactivate_landing (u : Fin nU) : (w.reactivate u).landing = w.landing := by
  unfold reactivate; split <;> rfl

/-- After `reactivate u`, `u`'s intent is open, and every intent that was open stays open. -/
theorem reactivate_open (u : Fin nU) (i : Fin nI) :
    ((w.reactivate u).intent i).isOpen = true ↔
      (i = (w.unit u).intent ∨ (w.intent i).isOpen = true) := by
  unfold reactivate
  split
  · rename_i h
    constructor
    · intro h'; exact Or.inr h'
    · rintro (rfl | h'); exact h; exact h'
  · simp only [setIntent_intent]
    by_cases hi : i = (w.unit u).intent
    · simp [hi, IntentState.isOpen]
    · simp [hi]

theorem isOpen_of_active_inv {u : Fin nU} (hinv : w.ActiveIntentOpen)
    (ha : (w.unit u).state.active = true) : (w.intent (w.unit u).intent).isOpen = true :=
  hinv u ha

/-! ## `TerminalUnitSync` preserves both invariants -/

theorem sync_unit (u : Fin nU) : (w.sync u).unit = w.unit := by
  unfold sync; split
  · split <;> rfl
  · rfl
theorem sync_holder (u : Fin nU) : (w.sync u).holder = w.holder := by
  unfold sync; split
  · split <;> rfl
  · rfl

/-- `sync` only changes the intent of `u`, and only when no unit of that intent is active. -/
theorem sync_intent (u : Fin nU) (i : Fin nI) :
    (w.sync u).intent i = w.intent i ∨
      (i = (w.unit u).intent ∧ (w.unit u).state.terminal = true ∧ ¬ w.activeSibling u) := by
  unfold sync
  split
  · rename_i h
    split <;> first
      | (left; rfl)
      | (simp only [setIntent_intent]; by_cases hi : i = (w.unit u).intent
         · exact Or.inr ⟨hi, h.1, h.2.2⟩
         · simp [hi])
  · left; rfl

theorem sync_inv (u : Fin nU) (h : w.Inv) : (w.sync u).Inv := by
  obtain ⟨hl, ha⟩ := h
  refine ⟨?_, ?_⟩
  · intro k v hk
    rw [sync_holder] at hk; rw [sync_unit]; exact hl k v hk
  · intro v hv
    rw [sync_unit] at hv ⊢
    rcases sync_intent (w := w) u (w.unit v).intent with h1 | ⟨hi, hterm, hsib⟩
    · rw [h1]; exact ha v hv
    · exfalso
      by_cases hvu : v = u
      · subst hvu; simp [UnitState.active, hterm] at hv
      · exact hsib ⟨v, hvu, hi, hv⟩

/-! ## Lifecycle operations preserve the invariants -/

theorem block_inv (u : Fin nU) (r : BlockReason) (h : w.Inv) : (w.block u r).Inv := by
  obtain ⟨hl, ha⟩ := h
  have base : ((w.reactivate u).setState u .blocked).Inv := by
    refine ⟨?_, ?_⟩
    · intro k v hk
      simp only [setState_holder, reactivate_holder] at hk
      simp only [setState_unit, reactivate_unit]
      by_cases hv : v = u
      · simp [hv, UnitState.active, UnitState.terminal]
      · simp [hv]; exact hl k v hk
    · intro v hv
      simp only [setState_unit, reactivate_unit, setState_intent] at hv ⊢
      rw [reactivate_open]
      by_cases hvu : v = u
      · subst hvu; simp
      · simp [hvu] at hv ⊢; exact Or.inr (ha v hv)
  unfold block
  cases r
  · refine ⟨?_, base.2⟩
    intro k v hk
    exact base.1 k v (releaseWhere_sub hk)
  · exact base

theorem unblock_inv (u : Fin nU) (h : w.Inv) : (w.unblock u).Inv := by
  obtain ⟨hl, ha⟩ := h
  refine ⟨?_, ?_⟩
  · intro k v hk
    simp only [unblock, setState_holder, reactivate_holder] at hk
    simp only [unblock, setState_unit, reactivate_unit]
    by_cases hv : v = u
    · simp [hv, UnitState.active, UnitState.terminal]
    · simp [hv]; exact hl k v hk
  · intro v hv
    simp only [unblock, setState_unit, reactivate_unit, setState_intent] at hv ⊢
    rw [reactivate_open]
    by_cases hvu : v = u
    · subst hvu; simp
    · simp [hvu] at hv ⊢; exact Or.inr (ha v hv)

theorem markRunning_inv (u : Fin nU) {w' : World nI nU nK}
    (h : w.Inv) (hrun : w.markRunning u = some w') : w'.Inv := by
  obtain ⟨hl, ha⟩ := h
  unfold markRunning ensureLocks at hrun
  split at hrun
  · simp at hrun
  · simp only [Option.map_some, Option.some.injEq] at hrun
    subst hrun
    refine ⟨?_, ?_⟩
    · intro k v hk
      simp only [setState_holder] at hk
      simp only [setState_unit, reactivate_unit]
      by_cases hv : v = u
      · simp [hv, UnitState.active, UnitState.terminal]
      · simp only [hv, ite_false]
        split at hk
        · cases hk; exact absurd rfl hv
        · rw [reactivate_holder] at hk; exact hl k v hk
    · intro v hv
      simp only [setState_unit, reactivate_unit, setState_intent] at hv ⊢
      rw [reactivate_open]
      by_cases hvu : v = u
      · subst hvu; simp
      · simp [hvu] at hv ⊢; exact Or.inr (ha v hv)

theorem markTerminal_inv (u : Fin nU) (s : UnitState) {w' : World nI nU nK}
    (h : w.Inv) (hrun : w.markTerminal u s = some w') : w'.Inv := by
  obtain ⟨hl, ha⟩ := h
  unfold markTerminal at hrun
  split at hrun
  · rename_i hs
    simp only [Option.some.injEq] at hrun
    subst hrun
    apply sync_inv
    refine ⟨?_, ?_⟩
    · intro k v hk
      simp only [releaseAll_holder, setState_holder] at hk
      simp only [releaseAll_unit, setState_unit]
      by_cases hc : w.holder k = some u
      · simp [hc] at hk
      · simp only [hc, ite_false] at hk
        by_cases hv : v = u
        · subst hv; exact absurd hk hc
        · simp [hv]; exact hl k v hk
    · intro v hv
      simp only [releaseAll_unit, releaseAll_intent, setState_unit, setState_intent] at hv ⊢
      by_cases hvu : v = u
      · subst hvu; simp [UnitState.active, hs] at hv
      · simp [hvu] at hv ⊢; exact ha v hv
  · simp at hrun

theorem preempt_inv (u : Fin nU) (r : Reason) (h : w.Inv) : (w.preempt u r).Inv := by
  obtain ⟨hl, ha⟩ := h
  unfold preempt
  split
  · apply sync_inv
    refine ⟨?_, ?_⟩
    · intro k v hk
      simp only [setUnit_holder] at hk
      simp only [setUnit_unit]
      by_cases hv : v = u
      · subst hv; simp; exact hl k _ hk
      · simp [hv]; exact hl k v hk
    · intro v hv
      simp only [setUnit_unit, setUnit_intent] at hv ⊢
      by_cases hvu : v = u
      · subst hvu; simp at hv ⊢; exact ha v hv
      · simp [hvu] at hv ⊢; exact ha v hv
  · split
    · apply sync_inv
      refine ⟨?_, ?_⟩
      · intro k v hk
        simp only [releaseAll_holder, setUnit_holder] at hk
        simp only [releaseAll_unit, setUnit_unit]
        by_cases hc : w.holder k = some u
        · simp [hc] at hk
        · simp only [hc, ite_false] at hk
          by_cases hv : v = u
          · subst hv; exact absurd hk hc
          · simp [hv]; exact hl k v hk
      · intro v hv
        simp only [releaseAll_unit, releaseAll_intent, setUnit_unit, setUnit_intent] at hv ⊢
        by_cases hvu : v = u
        · subst hvu; simp [UnitState.active, UnitState.terminal] at hv
        · simp [hvu] at hv ⊢; exact ha v hv
    · exact ⟨hl, ha⟩

/-! ## Outcome stability, and the caller obligation it needs -/

/-- `preempt!` never rewrites a `succeeded`/`failed` unit. -/
theorem preempt_keeps_outcomes (u : Fin nU) (r : Reason) : w.OutcomesKept (w.preempt u r) := by
  intro v hv
  unfold preempt
  split
  · rename_i hc
    rw [sync_unit]; simp only [setUnit_unit]
    by_cases hvu : v = u
    · subst hvu; simp
    · simp [hvu]
  · split
    · rename_i _ hact
      rw [sync_unit]; simp only [releaseAll_unit, setUnit_unit]
      by_cases hvu : v = u
      · subst hvu
        cases hs : (w.unit v).state <;> simp_all [UnitState.outcome, UnitState.active, UnitState.terminal]
      · simp [hvu]
    · rfl

/-- `block!` keeps outcomes **only if** the caller never blocks a finished unit
    (see `Examples.finished` for what happens otherwise). -/
theorem block_keeps_outcomes (u : Fin nU) (r : BlockReason)
    (hact : (w.unit u).state.active = true) : w.OutcomesKept (w.block u r) := by
  intro v hv
  have : v ≠ u := by
    rintro rfl
    cases hs : (w.unit v).state <;> simp_all [UnitState.outcome, UnitState.active, UnitState.terminal]
  unfold block
  cases r <;> simp [reactivate_unit, this]

theorem markTerminal_keeps_outcomes (u : Fin nU) (s : UnitState) {w' : World nI nU nK}
    (hact : (w.unit u).state.active = true) (hrun : w.markTerminal u s = some w') :
    w.OutcomesKept w' := by
  intro v hv
  have : v ≠ u := by
    rintro rfl
    cases hs : (w.unit v).state <;> simp_all [UnitState.outcome, UnitState.active, UnitState.terminal]
  unfold markTerminal at hrun
  split at hrun
  · simp only [Option.some.injEq] at hrun; subst hrun
    rw [sync_unit]; simp [this]
  · simp at hrun

/-! ## Reconciler repairs -/

/-- Under the invariant, `classify_terminal_work_units_with_active_locks` never
    fires: it only detects states the lifecycle methods cannot produce. -/
theorem inv_no_terminal_locks (h : w.Inv) (u : Fin nU) : ¬ w.terminalWithLocks u := by
  rintro ⟨hterm, k, hk⟩
  have := h.1 k u hk
  simp [UnitState.active, hterm] at this

theorem releaseAll_idem (u : Fin nU) : (w.releaseAll u).releaseAll u = w.releaseAll u := by
  unfold releaseAll releaseWhere
  congr 1
  funext k
  by_cases hk : w.holder k = some u <;> simp [hk]

theorem releaseTerminalLocks_clears (u : Fin nU) : ¬ (w.releaseTerminalLocks u).terminalWithLocks u := by
  unfold releaseTerminalLocks
  by_cases h : (w.unit u).state.terminal = true
  · simp only [h, ite_true]
    rintro ⟨_, k, hk⟩
    simp only [releaseAll_holder] at hk
    by_cases hc : w.holder k = some u <;> simp [hc] at hk
  · simp only [h]
    rintro ⟨hterm, _⟩
    exact h hterm

theorem releaseTerminalLocks_idem (u : Fin nU) :
    (w.releaseTerminalLocks u).releaseTerminalLocks u = w.releaseTerminalLocks u := by
  unfold releaseTerminalLocks
  by_cases h : (w.unit u).state.terminal = true
  · simp only [h, ite_true, releaseAll_unit, releaseAll_idem]
  · simp [h]

theorem releaseTerminalLocks_inv (u : Fin nU) (h : w.Inv) : (w.releaseTerminalLocks u).Inv := by
  unfold releaseTerminalLocks
  split
  · exact ⟨fun k v hk => by
      simp only [releaseAll_holder] at hk; simp only [releaseAll_unit]
      split at hk
      · cases hk
      · exact h.1 k v hk, h.2⟩
  · exact h

theorem satisfyFromSucceeded_clears (u : Fin nU) :
    ¬ (w.satisfyFromSucceeded u).succeededUnsatisfied u := by
  unfold satisfyFromSucceeded
  split
  · rintro ⟨_, hopen, _⟩
    simp [IntentState.isOpen] at hopen
  · assumption

theorem satisfyFromSucceeded_idem (u : Fin nU) :
    (w.satisfyFromSucceeded u).satisfyFromSucceeded u = w.satisfyFromSucceeded u := by
  have hc := satisfyFromSucceeded_clears (w := w) u
  generalize w.satisfyFromSucceeded u = w' at hc ⊢
  unfold satisfyFromSucceeded
  simp [hc]

theorem satisfyFromSucceeded_inv (u : Fin nU) (h : w.Inv) : (w.satisfyFromSucceeded u).Inv := by
  unfold satisfyFromSucceeded
  split
  · rename_i hc
    obtain ⟨hs, _, hsib⟩ := hc
    refine ⟨h.1, ?_⟩
    intro v hv
    simp only [setIntent_unit, setIntent_intent] at hv ⊢
    split
    · rename_i hi
      exfalso
      by_cases hvu : v = u
      · subst hvu; simp [hs, UnitState.active, UnitState.terminal] at hv
      · exact hsib ⟨v, hvu, hi, hv⟩
    · exact h.2 v hv
  · exact h

theorem failFromFailed_inv (u : Fin nU) (h : w.Inv) : (w.failFromFailed u).Inv := by
  unfold failFromFailed
  split
  · rename_i hc
    obtain ⟨hs, _, hsib⟩ := hc
    refine ⟨h.1, ?_⟩
    intro v hv
    simp only [setIntent_unit, setIntent_intent] at hv ⊢
    split
    · rename_i hi
      exfalso
      by_cases hvu : v = u
      · subst hvu; simp [hs, UnitState.active, UnitState.terminal] at hv
      · exact hsib ⟨v, hvu, hi, hv⟩
    · exact h.2 v hv
  · exact h

theorem cancelWithoutWorkflow_clears (u : Fin nU) :
    ¬ (w.cancelWithoutWorkflow u).activeWithoutWorkflow u := by
  unfold cancelWithoutWorkflow
  split
  · rename_i hc
    rintro ⟨hact, _⟩
    unfold preempt at hact
    have hnc : (w.unit u).state ≠ .cancelled := by
      intro he; simp [he, UnitState.active, UnitState.terminal] at hc
    simp only [hnc, hc.1, ite_false, ite_true] at hact
    rw [sync_unit] at hact
    simp [UnitState.active, UnitState.terminal] at hact
  · assumption

theorem cancelWithoutWorkflow_inv (u : Fin nU) (h : w.Inv) : (w.cancelWithoutWorkflow u).Inv := by
  unfold cancelWithoutWorkflow; split
  · exact preempt_inv u _ h
  · exact h

theorem clearWaiting_inv (i : Fin nI) (h : w.Inv) : (w.clearWaiting i).Inv := by
  unfold clearWaiting; split
  · refine ⟨h.1, ?_⟩
    intro v hv
    simp only [setIntent_unit, setIntent_intent] at hv ⊢
    split
    · rfl
    · exact h.2 v hv
  · exact h

theorem cancelChild_inv (c : Fin nU) (h : w.Inv) : (w.cancelChild c).Inv := by
  unfold cancelChild; split
  · exact preempt_inv c _ h
  · exact h

end World
end SyrusModel
