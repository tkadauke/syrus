/-!
# Which Jobs a landing bundle may take

`LandingBundleAssembler::Scopes::PriorityTier` picks the members of an
epicless job bundle. Every member merges in one integration branch, so a member
whose prerequisite is not merged and not in the bundle would land ahead of it.
The scope keeps only candidates whose prerequisites are satisfied or are
candidates themselves (a fixpoint), orders them by dependency, and then caps the
list at `merge_train_max_size` with `capped_members`:

* if the cap cuts through a dependency-connected set that fits the cap (and is
  at least `MIN_BUNDLE_SIZE`), take that whole connected set;
* otherwise take the longest prefix within the cap that cuts off no
  prerequisite of an included member.

Candidates are their dependency-order positions `0 … n-1`; an edge `(a, b)`
says `a` depends on `b`, so `b < a`. This file mirrors `capped_members`,
`coalesced_dependency_members` and `cuts_off_prerequisite?` and checks, for
every such graph on up to five candidates and every cap:

* `members_closed_under_prerequisites`: every prerequisite of a member is a
  member;
* `members_within_cap`: never more members than the cap;
* `uncapped_takes_everything`: under the cap, every candidate is taken.
-/

namespace SyrusModel
namespace BundleSelection

abbrev Edge := Nat × Nat

def minBundle : Nat := 2

def subsets {α} : List α → List (List α)
  | [] => [[]]
  | x :: xs => let r := subsets xs; r ++ r.map (x :: ·)

/-- Every graph whose edges point from a later candidate to an earlier one. -/
def graphs (n : Nat) : List (List Edge) :=
  subsets ((List.range n).flatMap fun a => (List.range a).map fun b => (a, b))

/-- Undirected closure of `seed` over the dependency links. -/
def closure (edges : List Edge) : Nat → List Nat → List Nat
  | 0, ids => ids
  | fuel + 1, ids =>
    let next := (ids ++ edges.flatMap fun (a, b) => if ids.contains a || ids.contains b then [a, b] else []).eraseDups
    if next.length == ids.length then ids else closure edges fuel next

def coalesced (n cap : Nat) (edges : List Edge) : Option (List Nat) :=
  let cut := (List.range n).filter (· < cap)
  let overflow := (List.range n).filter (· ≥ cap)
  let crossing := edges.filter fun (a, b) => (cut.contains a && overflow.contains b) || (cut.contains b && overflow.contains a)
  if crossing.isEmpty then none else
    let seeds := (crossing.flatMap fun (a, b) => [a, b]).eraseDups
    let connected := closure edges (n + 1) seeds
    if connected.length > cap || connected.length < minBundle then none
    else some ((List.range n).filter connected.contains)

def cutsOff (n cut : Nat) (edges : List Edge) : Bool :=
  edges.any fun (a, b) => a < cut && b ≥ cut && b < n

def prefixCut (n cap : Nat) (edges : List Edge) : Nat → Nat
  | 0 => 0
  | c + 1 => if cutsOff n (c + 1) edges then prefixCut n cap edges c else c + 1

/-- `capped_members` over the dependency-ordered candidates `0 … n-1`. -/
def capped (n cap : Nat) (edges : List Edge) : List Nat :=
  if n ≤ cap then List.range n
  else match coalesced n cap edges with
    | some members => members
    | none => List.range (prefixCut n cap edges cap)

def closed (edges : List Edge) (members : List Nat) : Bool :=
  edges.all fun (a, b) => !members.contains a || members.contains b

def check (maxN : Nat) (p : Nat → Nat → List Edge → Bool) : Bool :=
  (List.range (maxN + 1)).all fun n =>
    (List.range (maxN + 1)).all fun cap => (graphs n).all (p n cap)

theorem members_closed_under_prerequisites :
    check 5 (fun n cap g => closed g (capped n cap g)) = true := by native_decide

theorem members_within_cap :
    check 5 (fun n cap g => (capped n cap g).length ≤ cap || n ≤ cap) = true := by native_decide

theorem uncapped_takes_everything :
    check 5 (fun n cap g => !(n ≤ cap) || capped n cap g == List.range n) = true := by native_decide

/-- The cap keeps linked Jobs together: candidate 2 depends on candidate 1
and the cap (2) falls between them, so the bundle takes the connected pair
rather than the plain prefix `[0, 1]`. In dependency order a prerequisite always
precedes its dependent, so the prefix rule only matters for the order's cycle
fallback (LandingOrder.lean). -/
theorem cap_keeps_linked_jobs_together :
    capped 3 2 [(2, 1)] = [1, 2] := by native_decide

end BundleSelection
end SyrusModel
