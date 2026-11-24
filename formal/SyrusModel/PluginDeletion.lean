/-!
# Deleting a plugin leaves a closed system (pilot)

`bin/plugin-boundary-audit P` removes plugin `P` and every plugin that
transitively depends on it, then boots what is left. This file states what that
run checks, as a property of a dependency graph:

* nodes are source units (files, tables, routes, frontend modules), each owned by
  core or by one plugin;
* an edge `a → b` means `a` needs `b` to load or run;
* deleting `P` removes every node owned by `P` or by a plugin that depends on `P`.

The kept system is **closed** when nothing it can reach was removed. The
theorem `closed_of_no_crossing` proves, for every graph, that it is enough to
check the edges that leave a kept node: if none of them enters the removed set,
every node reachable from a kept node is kept. That turns a 20-minute boot of a
reduced tree into a scan of one edge list per plugin.

The proof is only as good as the edge list. Edges the extractor cannot resolve
(a `constantize` on a computed string, raw SQL) are `unknown` and make the
plugin fall back to the real deletion run (`decide_with_unknowns`).
-/

namespace SyrusModel
namespace PluginDeletion

/-- Who owns a node: core, or the plugin with this index. -/
inductive Owner | core | plugin (p : Nat)
  deriving DecidableEq, Repr

/-- `deps p` are plugin `p`'s declared hard dependencies. -/
abbrev PluginDeps := Nat → List Nat

/-- Plugins removed with `target`: itself and every plugin that depends on it,
transitively, found with `fuel` rounds (the number of plugins is enough). -/
def removedPlugins (plugins : List Nat) (deps : PluginDeps) (target : Nat) : Nat → List Nat
  | 0 => [target]
  | fuel + 1 =>
    let prev := removedPlugins plugins deps target fuel
    prev ++ plugins.filter (fun q => !prev.contains q && (deps q).any prev.contains)

def removedOwner (removed : List Nat) : Owner → Bool
  | .core => false
  | .plugin p => removed.contains p

/-- A graph over nodes `0..n-1`: `owner` per node and directed edges. -/
structure Graph where
  owner : Nat → Owner
  edges : List (Nat × Nat)

def Graph.removed (g : Graph) (removed : List Nat) (v : Nat) : Bool := removedOwner removed (g.owner v)

/-- `v` is reachable from `u` (reflexive, transitive closure of `edges`). -/
inductive Reach (g : Graph) : Nat → Nat → Prop
  | refl (u : Nat) : Reach g u u
  | step {u v w : Nat} : (u, v) ∈ g.edges → Reach g v w → Reach g u w

/-- No edge leaves a kept node into the removed set. This is the per-plugin
check: one pass over the edge list. -/
def noCrossing (g : Graph) (removed : List Nat) : Prop :=
  ∀ u v, (u, v) ∈ g.edges → g.removed removed u = false → g.removed removed v = false

/-- **Closure.** If no edge crosses from kept to removed, everything a kept node
can reach is kept: the reduced system needs nothing that was deleted. -/
theorem closed_of_no_crossing (g : Graph) (removed : List Nat) (h : noCrossing g removed) :
    ∀ u w, Reach g u w → g.removed removed u = false → g.removed removed w = false := by
  intro u w hr
  induction hr with
  | refl => exact id
  | step he _ ih => exact fun hu => ih (h _ _ he hu)

/-- And conversely, a single crossing edge is a node the reduced system needs
but no longer has. -/
theorem crossing_breaks (g : Graph) (removed : List Nat) (u v : Nat)
    (he : (u, v) ∈ g.edges) (hu : g.removed removed u = false) (hv : g.removed removed v = true) :
    ∃ w, Reach g u w ∧ g.removed removed w = true :=
  ⟨v, Reach.step he (Reach.refl v), hv⟩

/-- The decidable check the extractor's output is run through. -/
def crossingEdges (g : Graph) (removed : List Nat) : List (Nat × Nat) :=
  g.edges.filter (fun (u, v) => !g.removed removed u && g.removed removed v)

theorem noCrossing_of_empty (g : Graph) (removed : List Nat) (h : crossingEdges g removed = []) :
    noCrossing g removed := by
  intro u v he hu
  cases hv : g.removed removed v
  · rfl
  · have : (u, v) ∈ crossingEdges g removed := by
      simp [crossingEdges, List.mem_filter, he, hu, hv]
    rw [h] at this
    simp at this

/-- Verdict for one plugin: safe, needs the real deletion run (an unresolved
edge leaves a kept node), or broken (a crossing edge, with a witness). -/
inductive Verdict | safe | needsRun | broken
  deriving DecidableEq, Repr

def decide_with_unknowns (g : Graph) (removed : List Nat) (unknownFrom : List Nat) : Verdict :=
  if !(crossingEdges g removed).isEmpty then .broken
  else if unknownFrom.any (fun u => !g.removed removed u) then .needsRun
  else .safe

theorem safe_means_closed (g : Graph) (removed : List Nat) (unknownFrom : List Nat)
    (h : decide_with_unknowns g removed unknownFrom = .safe) :
    ∀ u w, Reach g u w → g.removed removed u = false → g.removed removed w = false := by
  apply closed_of_no_crossing
  apply noCrossing_of_empty
  unfold decide_with_unknowns at h
  by_cases hc : (crossingEdges g removed).isEmpty
  · exact List.isEmpty_iff.mp hc
  · simp [hc] at h

/-- Example: plugins 0 and 1, where 1 depends on 0. Deleting 0 removes 1 too. -/
example : removedPlugins [0, 1] (fun q => if q = 1 then [0] else []) 0 2 = [0, 1] := by decide

end PluginDeletion
end SyrusModel
