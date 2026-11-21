/-!
# DOC-44 frontend: what the entity store's revision merge guarantees

DOC-44 frontend invariants: "Accepted entity revisions never decrease," "For
one entity, the higher revision wins regardless of arrival order," and "An
older REST response cannot overwrite a newer cable patch."

`upsertEntity` (`app/frontend/lib/entityStore.ts`) rejects an incoming write
whose revision is below the stored one, and otherwise merges its fields over
the stored ones, keeping the higher revision. Modelled over every order of up
to three writes with revisions 0 to 2, each setting a subset of two fields:

- The stored revision never decreases, whatever the order (`monotone`).
- Full writes (every field present) with distinct revisions end in the same
  state in every order: the highest revision's fields
  (`full_writes_commute`). So an older REST snapshot cannot overwrite a newer
  cable patch.

What it does not guarantee, and what Syrus relies on instead:

- A *partial* patch at revision N+1 lifts the entity to N+1 while keeping, for
  fields the patch did not carry, values written at N. They are then labelled
  N+1 although they may have changed at N+1 (`partial_patch_relabels`).
- Two writes at the same revision resolve by arrival order. `JobEventFields`
  carries `start_blocked_*`, which is derived from WorkUnits and changes
  without the Job's revision moving. A job-detail snapshot already in flight
  can therefore briefly restore an older blocked reason.

Both converge, because every job-level event also invalidates the job queries,
and the refetch it triggers is a newer full snapshot. Both are recorded in
FINDINGS M18.
-/

namespace SyrusModel
namespace EntityMerge

/-- Two fields; `none` means the write does not carry it. -/
structure Write where
  rev : Nat
  a : Option Nat
  b : Option Nat
deriving DecidableEq, Repr

structure Entity where
  rev : Nat
  a : Option Nat
  b : Option Nat
deriving DecidableEq, Repr

def upsert : Option Entity → Write → Option Entity
  | none, w => some ⟨w.rev, w.a, w.b⟩
  | some e, w =>
    if w.rev < e.rev then some e
    else some ⟨max e.rev w.rev, w.a.orElse (fun _ => e.a), w.b.orElse (fun _ => e.b)⟩

def run (ws : List Write) : Option Entity := ws.foldl upsert none

def permutations : List Write → List (List Write)
  | [] => [[]]
  | x :: xs => (permutations xs).flatMap (fun p =>
      (List.range (p.length + 1)).map (fun i => p.take i ++ [x] ++ p.drop i))

def revs : List (Option Entity) → List Nat := List.filterMap (·.map (·.rev))

def nondecreasing : List Nat → Bool
  | a :: b :: rest => a ≤ b && nondecreasing (b :: rest)
  | _ => true

def prefixes (ws : List Write) : List (Option Entity) := (List.range (ws.length + 1)).map (fun i => run (ws.take i))

def vals : List (Option Nat) := [none, some 0, some 1]

def writes : List Write :=
  (List.range 3).flatMap (fun r => vals.flatMap (fun a => vals.map (fun b => ⟨r, a, b⟩)))

def triples : List (List Write) :=
  writes.flatMap (fun x => writes.flatMap (fun y => [[x, y]] ++ writes.map (fun z => [x, y, z])))

theorem monotone : (triples.all (fun ws => (permutations ws).all (fun p => nondecreasing (revs (prefixes p))))) = true := by
  native_decide

def fullWrites : List Write := writes.filter (fun w => w.a.isSome && w.b.isSome)

def distinctRevs (ws : List Write) : Bool := (ws.map (·.rev)).eraseDups.length == ws.length

def fullTriples : List (List Write) :=
  fullWrites.flatMap (fun x => fullWrites.flatMap (fun y => [[x, y]] ++ fullWrites.map (fun z => [x, y, z])))

theorem full_writes_commute :
    (fullTriples.filter distinctRevs).all (fun ws =>
      let results := (permutations ws).map run
      results.all (· == results.headD none)) = true := by
  native_decide

/-- A partial patch at revision 1 keeps field `b` from revision 0 and labels it
    revision 1. -/
theorem partial_patch_relabels :
    run [⟨0, some 0, some 0⟩, ⟨1, some 1, none⟩] = some ⟨1, some 1, some 0⟩ := by
  decide

end EntityMerge
end SyrusModel
