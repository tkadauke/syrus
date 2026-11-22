/-!
# Landing units deadlock on a cycle the Job graph does not have

Coverage item `landing-queue-order` (the unmodelled order computation).
`LandingQueueProcessor` lands *units*: every Job of an Epic is one unit, the
Epic's merge train, and an Epic-less Job is a unit of its own. A unit is
blocked while any transitive landing prerequisite *outside* it is not closed
(`transitive_blocker_jobs_for`, `dependency_blocker?`).

`JobDependency#no_cycle` rejects cycles in the *Job* graph only. Contracting an
Epic to one unit can create a cycle the Job graph lacks. For example, Epic
child J1 ← outside Job J2 ← Epic child J3:

* the Epic's unit {J1, J3} waits for J2 (J3's prerequisite) to land;
* J2's unit waits for J1, which only lands with the Epic's train.

Neither ever unblocks (`epic_through_outside_job_deadlocks`). The cyclic
remainder of `ordered_landing_units` keeps both in the queue but cannot land
either.

The safe condition is acyclicity of the *contracted* graph. Over every
assignment of four Jobs to at most two Epics and every dependency relation on
them, if the unit graph is acyclic then some open unit has no open outside
prerequisite, so the queue always has something it may land
(`contracted_acyclic_progress`). The Job-level check alone does not guarantee
this (`job_acyclic_not_enough`).

Production (read-only) has never had the shape, so this is latent: NY28 asks
whether to reject such a dependency at creation.
-/

namespace SyrusModel
namespace LandingUnitCycle

abbrev n : Nat := 4

/-- `epic i = 0` means Epic-less; Epics are 1 and 2. -/
abbrev EpicOf := Fin n → Nat
/-- `dep i j`: Job i lands only after Job j (a landing prerequisite). -/
abbrev Deps := Fin n → Fin n → Bool

def jobs : List (Fin n) := List.finRange n

/-- The unit a Job lands in: its Epic, or itself. -/
def unitOf (e : EpicOf) (i : Fin n) : Nat := if e i = 0 then 10 + i.val else e i

def sameUnit (e : EpicOf) (i j : Fin n) : Bool := unitOf e i == unitOf e j

/-- Transitive closure (Warshall), computed once as a table. -/
def closure (r : Fin n → Fin n → Bool) : Array (Array Bool) := Id.run do
  let mut m : Array (Array Bool) := (List.finRange n).toArray.map fun i => (List.finRange n).toArray.map (r i)
  for k in [0:n] do
    for i in [0:n] do
      for j in [0:n] do
        if m[i]![k]! && m[k]![j]! then
          m := m.set! i (m[i]!.set! j true)
  return m

def at? (m : Array (Array Bool)) (i j : Fin n) : Bool := m[i.val]![j.val]!

/-- A unit (named by any of its Jobs) is blocked if some Job in it has a
    transitive prerequisite outside the unit. Nothing has landed yet: the
    question is whether the queue can make its first move at all. -/
def unitBlocked (e : EpicOf) (d : Deps) (u : Fin n) : Bool :=
  let c := closure d
  jobs.any fun i => sameUnit e i u && jobs.any fun j => at? c i j && !sameUnit e i j

def someUnitFree (e : EpicOf) (d : Deps) : Bool :=
  let c := closure d
  jobs.any fun u => !(jobs.any fun i => sameUnit e i u && jobs.any fun j => at? c i j && !sameUnit e i j)

def jobAcyclic (d : Deps) : Bool := let c := closure d; jobs.all fun i => !at? c i i

/-- Unit-graph edges, and acyclicity of the contracted graph. -/
def unitEdge (e : EpicOf) (d : Deps) (a b : Fin n) : Bool :=
  jobs.any fun i => jobs.any fun j => sameUnit e i a && sameUnit e j b && d i j && !sameUnit e i j

def unitAcyclic (e : EpicOf) (d : Deps) : Bool :=
  let c := closure (unitEdge e d)
  jobs.all fun a => !at? c a a

def epicVals : List Nat := [0, 1, 2]

def allEpics : List EpicOf :=
  epicVals.flatMap fun a => epicVals.flatMap fun b => epicVals.flatMap fun c => epicVals.map fun x =>
    fun i => match i.val with | 0 => a | 1 => b | 2 => c | _ => x

/-- Every dependency relation on four Jobs without self-edges, as a bitmask
    over the 12 ordered pairs. -/
def pairs : List (Fin n × Fin n) := jobs.flatMap fun i => (jobs.filter (· != i)).map (i, ·)

def depsOf (mask : Nat) : Deps := fun i j =>
  match pairs.findIdx? (· == (i, j)) with
  | some k => (mask >>> k) % 2 == 1
  | none => false

def check : Bool :=
  allEpics.all fun e => (List.range (2 ^ pairs.length)).all fun mask =>
    let d := depsOf mask
    !unitAcyclic e d || someUnitFree e d

theorem contracted_acyclic_progress : check = true := by native_decide

/-- J0 and J2 in Epic 1, J1 outside; J1 needs J0, J2 needs J1. -/
def cexEpic : EpicOf := fun i => match i.val with | 0 => 1 | 2 => 1 | _ => 0
def cexDeps : Deps := fun i j => (i.val == 1 && j.val == 0) || (i.val == 2 && j.val == 1)

theorem epic_through_outside_job_deadlocks :
    unitBlocked cexEpic cexDeps 0 = true ∧ unitBlocked cexEpic cexDeps 1 = true := by
  native_decide

theorem job_acyclic_not_enough :
    jobAcyclic cexDeps = true ∧ unitAcyclic cexEpic cexDeps = false := by
  native_decide

end LandingUnitCycle
end SyrusModel
