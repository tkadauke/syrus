/-!
# The landing queue's order computation

`LandingQueueProcessor#ordered_landing_units` (and `#dependency_order`, the
same algorithm over the Jobs of one unit) orders landing candidates: units
start in queue order (priority, then approval time), and a unit whose
prerequisite Job is in another queued unit goes after that unit. It is Kahn's
algorithm with the ready set kept sorted by queue position; whatever a cycle
leaves unordered is appended in queue order.

Units are their queue positions `0 … n-1`; an edge `(a, b)` says `a` must land
before `b`. This file mirrors the algorithm step for step and checks, for
every dependency graph on up to four units (self-loops included):

* `order_is_permutation`: every unit appears exactly once, cycle or not;
* `acyclic_order_respects_edges`: with no cycle, every prerequisite lands
  first;
* `acyclic_order_is_least_topological`: with no cycle, the order is the
  lexicographically least order that respects the edges, so the queue is as
  chronological as the dependencies allow and no unit is pushed back further
  than its prerequisites require;
* `no_edges_keeps_queue_order`: without dependencies the order is the queue;
* `cyclic_prefix_respects_edges`: with a cycle, the ordered prefix still lands
  each of its units after all of that unit's prerequisites; only the fallback
  tail ignores edges, and `LandingUnitCycle.lean` (M50, F107) covers why such a
  tail cannot form in practice.
-/

namespace SyrusModel
namespace LandingOrder

abbrev Edge := Nat × Nat

def insertSorted (x : Nat) : List Nat → List Nat
  | [] => [x]
  | y :: ys => if x ≤ y then x :: y :: ys else y :: insertSorted x ys

def sortNat (l : List Nat) : List Nat := l.foldr insertSorted []

/-- Kahn's algorithm as `ordered_landing_units` runs it. `incoming` is the set
of unprocessed prerequisites of each unit. -/
def kahnAux (edges : List Edge) : Nat → List Nat → List (List Nat) → List Nat → List Nat
  | 0, _, _, ordered => ordered
  | fuel + 1, ready, incoming, ordered =>
    match ready with
    | [] => ordered
    | u :: rest =>
      let dependents := sortNat ((edges.filter (·.1 = u)).map (·.2)).eraseDups
      let (incoming', newly) := dependents.foldl (fun (acc : List (List Nat) × List Nat) d =>
        let inc := acc.1.set d ((acc.1.getD d []).erase u)
        (inc, if (inc.getD d []).isEmpty && !(acc.1.getD d []).isEmpty then acc.2 ++ [d] else acc.2))
        (incoming, [])
      kahnAux edges fuel (sortNat (rest ++ newly)) incoming' (ordered ++ [u])

def order (n : Nat) (edges : List Edge) : List Nat :=
  let incoming := (List.range n).map fun b => ((edges.filter (·.2 = b)).map (·.1)).eraseDups
  let ready := (List.range n).filter fun b => (incoming.getD b []).isEmpty
  let ordered := kahnAux edges (n + 1) ready incoming []
  ordered ++ (List.range n).filter (fun u => !ordered.contains u)

def respects (edges : List Edge) (l : List Nat) : Bool :=
  edges.all fun (a, b) => match l.idxOf? a, l.idxOf? b with
    | some i, some j => i < j
    | _, _ => false

def permsAux : Nat → List Nat → List (List Nat)
  | 0, _ => [[]]
  | _ + 1, [] => [[]]
  | k + 1, l => l.flatMap fun x => (permsAux k (l.erase x)).map (x :: ·)

def perms (l : List Nat) : List (List Nat) := permsAux l.length l

def lexLt : List Nat → List Nat → Bool
  | [], _ :: _ => true
  | x :: xs, y :: ys => x < y || (x == y && lexLt xs ys)
  | _, _ => false

def allEdges (n : Nat) : List Edge :=
  (List.range n).flatMap fun a => (List.range n).map fun b => (a, b)

def subsets {α} : List α → List (List α)
  | [] => [[]]
  | x :: xs => let r := subsets xs; r ++ r.map (x :: ·)

/-- Every graph on `n` units, self-loops included. -/
def graphs (n : Nat) : List (List Edge) := subsets (allEdges n)

def topoOrders (n : Nat) (edges : List Edge) : List (List Nat) :=
  (perms (List.range n)).filter (respects edges)

def isPerm (n : Nat) (l : List Nat) : Bool :=
  l.length = n && (List.range n).all l.contains

def checkPerm (n : Nat) : Bool := (graphs n).all fun g => isPerm n (order n g)

def checkRespects (n : Nat) : Bool :=
  (graphs n).all fun g => (topoOrders n g).isEmpty || respects g (order n g)

def checkLeast (n : Nat) : Bool :=
  (graphs n).all fun g =>
    let o := order n g
    (topoOrders n g).isEmpty || (topoOrders n g).all fun t => !lexLt t o

/-- The Kahn prefix (before the fallback tail) puts each unit after every
prerequisite of it. -/
def prefixOk (n : Nat) (g : List Edge) : Bool :=
  let incoming := (List.range n).map fun b => ((g.filter (·.2 = b)).map (·.1)).eraseDups
  let ready := (List.range n).filter fun b => (incoming.getD b []).isEmpty
  let pre := kahnAux g (n + 1) ready incoming []
  pre.all fun b => g.all fun (a, b') => b' != b || match pre.idxOf? a, pre.idxOf? b with
    | some i, some j => i < j
    | _, _ => false

def checkPrefix (n : Nat) : Bool := (graphs n).all (prefixOk n)

theorem order_is_permutation : checkPerm 4 = true := by native_decide
theorem acyclic_order_respects_edges : checkRespects 4 = true := by native_decide
theorem acyclic_order_is_least_topological : checkLeast 4 = true := by native_decide
theorem cyclic_prefix_respects_edges : checkPrefix 4 = true := by native_decide

theorem no_edges_keeps_queue_order :
    (List.range 6).all (fun n => order n [] == List.range n) = true := by native_decide

/-- A later unit's prerequisite lands first; the unconstrained unit keeps its
place ahead of both, and a two-unit cycle falls back to queue order. -/
theorem witnesses :
    order 3 [(2, 0)] = [1, 2, 0] ∧ order 3 [(0, 1), (1, 0)] = [2, 0, 1] := by native_decide

end LandingOrder
end SyrusModel
