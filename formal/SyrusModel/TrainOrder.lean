/-!
# DOC-44 Phase 3: a merge train integrates exactly its members, in dependency order

DOC-44: "Merge-train integration content is exactly the declared member set in
dependency order"; "Dependencies precede dependents".

`LandingBundleAssembler` (Epic trains and epicless job bundles) orders the
selected members with `LandingQueueProcessor#dependency_order`: Kahn's
algorithm over the members' prerequisites (stack parent and resolved job
dependencies, unless overridden), ties broken by the members' original order,
and any members left over (a dependency cycle) appended in original order.
`MergeTrainDispatcher` / `JobBundleDispatcher` store that order as member
positions, and `Steps::MergeTrainBuild` integrates `train.member_jobs`
(ordered by position).

This file is that ordering, transcribed. Checked exhaustively over every
dependency graph on up to four members (`native_decide`):

* the result is a permutation of the members (`order_is_permutation`):
  nothing dropped, nothing duplicated, even with a cycle;
* for an acyclic graph every prerequisite precedes its dependent
  (`order_respects_dependencies`).

`spec/services/landing_queue_processor_dependency_order_spec.rb` checks the
Ruby method against the same two properties on random graphs. No bug found.
-/

namespace SyrusModel
namespace TrainOrder

/-- `deps j` are `j`'s prerequisites among the members (indices). -/
abbrev Graph := Nat → List Nat

/-- Kahn's algorithm as `dependency_order` runs it: always pick the
    lowest-index ready member. `fuel` bounds the loop (one pick per member). -/
def kahn (n : Nat) (deps : Graph) : Nat → List Nat → List Nat
  | 0, done => done
  | fuel + 1, done =>
    match (List.range n).find? (fun j => !done.contains j && (deps j).all (fun d => done.contains d || d ≥ n)) with
    | some j => kahn n deps fuel (done ++ [j])
    | none => done

/-- `ordered + jobs.reject { |job| ordered.include?(job) }` -/
def order (n : Nat) (deps : Graph) : List Nat :=
  let ordered := kahn n deps n []
  ordered ++ (List.range n).filter (fun j => !ordered.contains j)

def isPermutation (n : Nat) (xs : List Nat) : Bool :=
  xs.length == n && (List.range n).all (fun j => xs.count j == 1)

def respects (deps : Graph) (xs : List Nat) : Bool :=
  xs.zipIdx.all (fun (j, i) => (deps j).all (fun d => match xs.idxOf? d with
    | some k => k < i
    | none => true))

/-- No member reaches itself through prerequisites (depth `n` suffices). -/
def reach (deps : Graph) : Nat → Nat → List Nat
  | 0, _ => []
  | fuel + 1, j => (deps j) ++ (deps j).flatMap (reach deps fuel)

def acyclic (n : Nat) (deps : Graph) : Bool :=
  (List.range n).all (fun j => !(reach deps n j).contains j)

/-- Every graph on `n` members: each member's prerequisite set is a subset of
    the others, encoded as a bitmask. -/
def graphOf (n : Nat) (masks : List Nat) : Graph := fun j =>
  (List.range n).filter (fun d => d != j && (masks.getD j 0) / (2 ^ d) % 2 == 1)

def allMasks : Nat → Nat → List (List Nat)
  | 0, _ => [[]]
  | k + 1, n => (allMasks k n).flatMap (fun ms => (List.range (2 ^ n)).map (fun m => ms ++ [m]))

def checkAll (n : Nat) (p : Graph → Bool) : Bool := (allMasks n n).all (fun ms => p (graphOf n ms))

/-- The checks are not vacuous: a dependent placed before its prerequisite,
    or a dropped member, is caught. -/
example : respects (fun j => if j = 1 then [0] else []) [1, 0] = false := by decide
example : isPermutation 2 [0] = false := by decide

theorem order_is_permutation :
    (List.range 5).all (fun n => checkAll n (fun g => isPermutation n (order n g))) = true := by native_decide

theorem order_respects_dependencies :
    (List.range 5).all (fun n => checkAll n (fun g => !acyclic n g || respects g (order n g))) = true := by
  native_decide

end TrainOrder
end SyrusModel
