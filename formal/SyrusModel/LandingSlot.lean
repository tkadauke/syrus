/-!
# The repository landing slot

One landing runs per repository at a time; the landing slot is the mutex.
Before the fix, a landing parked mid-run on `no_capable_worker` *surrendered*
the slot (to avoid a 23-hour starvation) while staying in flight, so a second
landing could start and overlap it on a moved base: neither "a running landing
holds the slot" nor "nothing starves behind a landing that cannot proceed" held
cleanly.

Operator decision: a landing that cannot place its next step *fails*; it is
held — not re-launched — until a capable worker is live again.

Each landing is `idle`, `running` (holds the slot), or `held` (waiting for a
capable worker, holds nothing).
-/

namespace SyrusModel
namespace LandingSlot

inductive L where
  | idle | running | held
  deriving DecidableEq, Repr

structure World (n : Nat) where
  st : Fin n → L
  /-- Who holds the slot. -/
  slot : Option (Fin n)
  /-- A worker with the capability each landing needs is live. External. -/
  capable : Fin n → Bool

variable {n : Nat}

def upd {α : Type} (f : Fin n → α) (i : Fin n) (v : α) : Fin n → α :=
  fun j => if j = i then v else f j

namespace World
variable (s : World n)

/-- Running ⇔ holding the slot: mutual exclusion plus "a running landing always
    holds the slot". -/
def SlotExact : Prop := ∀ i, s.st i = .running ↔ s.slot = some i

instance : Decidable s.SlotExact := by unfold SlotExact; infer_instance

/-- Launch `i`: only when the slot is free, `i` is idle or held, and — if held —
    only once a capable worker is back (the hold). -/
def launch (i : Fin n) : World n :=
  if s.slot = none ∧ (s.st i = .idle ∨ (s.st i = .held ∧ s.capable i = true)) then
    { s with st := upd s.st i .running, slot := some i }
  else s

/-- The running landing cannot place a step: fail it, release the slot, hold it. -/
def cannotPlace (i : Fin n) : World n :=
  if s.st i = .running then { s with st := upd s.st i .held, slot := none } else s

/-- The running landing finishes (success or ordinary failure). -/
def finish (i : Fin n) : World n :=
  if s.st i = .running then { s with st := upd s.st i .idle, slot := none } else s

/-- The old behavior: park in flight and surrender the slot. -/
def parkSurrendering (i : Fin n) : World n :=
  if s.st i = .running then { s with slot := none } else s

end World

open World

theorem launch_exact {s : World n} (i : Fin n) (h : s.SlotExact) : (s.launch i).SlotExact := by
  unfold launch
  split
  · rename_i hc
    intro j
    simp only [upd]
    by_cases hj : j = i
    · subst hj; simp
    · simp only [hj, ite_false, Option.some.injEq]
      constructor
      · intro hr; have := (h j).1 hr; rw [hc.1] at this; cases this
      · intro he; exact absurd he.symm hj
  · exact h

theorem cannotPlace_exact {s : World n} (i : Fin n) (h : s.SlotExact) : (s.cannotPlace i).SlotExact := by
  unfold cannotPlace
  split
  · rename_i hr
    have hs : s.slot = some i := (h i).1 hr
    intro j
    simp only [upd]
    by_cases hj : j = i
    · subst hj; simp
    · simp only [hj, ite_false, reduceCtorEq, iff_false]
      intro hrj
      have := (h j).1 hrj
      rw [hs] at this
      exact hj (Option.some.inj this).symm
  · exact h

theorem finish_exact {s : World n} (i : Fin n) (h : s.SlotExact) : (s.finish i).SlotExact := by
  unfold finish
  split
  · rename_i hr
    have hs : s.slot = some i := (h i).1 hr
    intro j
    simp only [upd]
    by_cases hj : j = i
    · subst hj; simp
    · simp only [hj, ite_false, reduceCtorEq, iff_false]
      intro hrj
      have := (h j).1 hrj
      rw [hs] at this
      exact hj (Option.some.inj this).symm
  · exact h

/-- No starvation behind a landing that cannot proceed: right after it fails,
    the slot is free for another landing. -/
theorem cannotPlace_frees_slot {s : World n} (i : Fin n) (hr : s.st i = .running) :
    (s.cannotPlace i).slot = none := by
  simp [cannotPlace, hr]

/-- The hold: a held landing is never re-launched while no capable worker is live. -/
theorem held_not_relaunched {s : World n} (i : Fin n) (hh : s.st i = .held) (hc : s.capable i = false) :
    (s.launch i).st i = .held := by
  simp [launch, hh, hc]

/-- The old behavior breaks the slot contract: a landing still in flight no longer
    holds the slot, so a second one can launch alongside it. -/
theorem parkSurrendering_breaks :
    let s : World 2 := { st := fun i => if i = 0 then .running else .idle, slot := some 0, capable := fun _ => true }
    s.SlotExact ∧ ¬ (s.parkSurrendering 0).SlotExact ∧
      ((s.parkSurrendering 0).launch 1).st 0 = .running ∧ ((s.parkSurrendering 0).launch 1).st 1 = .running := by
  decide

end LandingSlot
end SyrusModel
