/-!
# DOC-44 plugin host: a contribution is callable only with a healthy dependency closure

DOC-44: "A contribution is callable only when its owner and complete required
dependency closure are installed, compatible, enabled, and healthy."

`Syrus::PluginRegistry.providers_for` returns the providers of plugins that are
enabled and `PluginHealth#healthy?`. Health marked a plugin degraded only for a
*direct* hard dependency that was missing or disabled, so a plugin stayed
healthy on top of an enabled dependency that was itself degraded, failed or
incompatible, and whose providers were withheld (`healthy_over_broken`). A
chain of any length had the same gap.

After the fix (`PluginHealth#propagate_unhealthy_dependencies`) an enabled
plugin whose enabled hard dependency is unhealthy is degraded too, to a fixed
point. Proved over every acyclic dependency graph on up to four plugins, with
every choice of locally broken plugins (`native_decide`): a plugin is healthy
exactly when it is locally sound and so is its whole required closure
(`healthy_iff_closure_sound`).

Separately, on a database error `providers_for` returns *every* registered
plugin's providers, disabled and unhealthy ones included. That is deliberate
for asset precompile and boot (pinned by "returns all plugins when the database
is unavailable") and is queued as NY13 for runtime database errors.
-/

namespace SyrusModel
namespace PluginClosure

/-- `deps p` are `p`'s hard dependencies (indices below `n`). -/
abbrev Graph := Nat → List Nat

/-- One propagation pass: a healthy plugin with an unhealthy dependency
    becomes unhealthy. -/
def step (n : Nat) (deps : Graph) (healthy : List Bool) : List Bool :=
  (List.range n).map (fun p => healthy.getD p false && (deps p).all (fun d => healthy.getD d false))

def iterate (n : Nat) (deps : Graph) : Nat → List Bool → List Bool
  | 0, h => h
  | k + 1, h => iterate n deps k (step n deps h)

/-- The fixed point (n passes suffice on an acyclic graph of n plugins). -/
def propagate (n : Nat) (deps : Graph) (sound : List Bool) : List Bool := iterate n deps n sound

/-- Locally sound and every dependency, transitively, locally sound. -/
def closureSound (deps : Graph) (sound : List Bool) : Nat → Nat → Bool
  | 0, p => sound.getD p false
  | fuel + 1, p => sound.getD p false && (deps p).all (closureSound deps sound fuel)

/-- Before: only direct dependencies' enablement mattered, so sound soundness
    alone decided (enabled dependencies assumed). -/
def before (sound : List Bool) (p : Nat) : Bool := sound.getD p false

/-- Dependencies only point to lower indices: every such graph is acyclic. -/
def graphOf (n : Nat) (masks : List Nat) : Graph := fun p =>
  (List.range n).filter (fun d => d < p && (masks.getD p 0) / (2 ^ d) % 2 == 1)

def allMasks : Nat → Nat → List (List Nat)
  | 0, _ => [[]]
  | k + 1, n => (allMasks k n).flatMap (fun ms => (List.range (2 ^ n)).map (fun m => ms ++ [m]))

def allBools : Nat → List (List Bool)
  | 0 => [[]]
  | k + 1 => (allBools k).flatMap (fun bs => [bs ++ [true], bs ++ [false]])

def check (n : Nat) : Bool :=
  (allMasks n n).all (fun ms => (allBools n).all (fun sound =>
    let g := graphOf n ms
    (List.range n).all (fun p => (propagate n g sound).getD p false == closureSound g sound n p)))

theorem healthy_iff_closure_sound : (List.range 5).all check = true := by native_decide

/-- The gap: `a` (index 1) depends on `b` (index 0), which is broken; `a`
    still read as healthy. -/
theorem healthy_over_broken :
    before [false, true] 1 = true ∧ (propagate 2 (fun p => if p = 1 then [0] else []) [false, true]).getD 1 false = false := by
  decide

end PluginClosure
end SyrusModel
