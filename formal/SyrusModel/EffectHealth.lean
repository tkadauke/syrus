import SyrusModel.PluginClosure

/-!
# DOC-44 plugin host: every contribution channel uses the same callable gate

DOC-44: "A contribution is callable only when its owner and complete required
dependency closure are installed, compatible, enabled, and healthy."

A plugin contributes through two channels. Providers go through
`PluginRegistry.providers_for`, which keeps plugins that are enabled *and*
healthy (`PluginClosure.healthy_iff_closure_sound`). `while_enabled` effects go
through `Syrus::Installer`, which installed every plugin that was merely
enabled. Effects are contributions too: chat session rehydrators, credential
probes, Coworkers' chat and schedule extensions. So a plugin that was degraded,
failed to load (`record_load_failure` keeps the operator's enabled flag), or
sat on a broken dependency kept its code callable through its effects while
its providers were withheld (`effects_outran_providers`).

That also closed a partial-registration hole: `Definition#install!` registers
the manifest, then `Installer.define`s its effects, then runs boot blocks. When
a boot block raises, the loader restores the registry snapshot and records the
plugin as failed, but the effect registrations survive the restore. With the
gate below they never install, because a failed plugin is unhealthy.

After the fix (`Installer.enabled_plugin_names` filters by
`PluginRegistry.health`), both channels use one predicate. Over every acyclic
dependency graph on up to three plugins, every enabled set and every set of
locally broken plugins (`native_decide`), the plugins whose effects install
are exactly those whose providers are handed out (`channels_agree`), and that
is exactly "enabled, and the whole required closure enabled and sound"
(`effects_iff_closure`).
-/

namespace SyrusModel
namespace EffectHealth

open PluginClosure

/-- Local soundness of an enabled plugin: not broken itself, and every hard
    dependency enabled (a disabled dependency degrades, `status_for`). -/
def localSound (n : Nat) (deps : Graph) (enabled broken : List Bool) : List Bool :=
  (List.range n).map (fun p =>
    !broken.getD p false && (deps p).all (fun d => enabled.getD d false))

def healthy (n : Nat) (deps : Graph) (enabled broken : List Bool) : List Bool :=
  propagate n deps (localSound n deps enabled broken)

/-- `providers_for`: enabled and healthy. -/
def providerCallable (n : Nat) (deps : Graph) (enabled broken : List Bool) (p : Nat) : Bool :=
  enabled.getD p false && (healthy n deps enabled broken).getD p false

/-- Installer before the fix: enabled only. -/
def effectBefore (enabled : List Bool) (p : Nat) : Bool := enabled.getD p false

/-- Installer after the fix: the same set `providers_for` uses. -/
def effectAfter (n : Nat) (deps : Graph) (enabled broken : List Bool) (p : Nat) : Bool :=
  enabled.getD p false && (healthy n deps enabled broken).getD p false

/-- Enabled, not broken, and every required dependency likewise, transitively. -/
def closureOk (deps : Graph) (enabled broken : List Bool) : Nat → Nat → Bool
  | 0, p => enabled.getD p false && !broken.getD p false
  | fuel + 1, p => enabled.getD p false && !broken.getD p false && (deps p).all (closureOk deps enabled broken fuel)

def check (n : Nat) : Bool :=
  (allMasks n n).all (fun ms => (allBools n).all (fun enabled => (allBools n).all (fun broken =>
    let g := graphOf n ms
    (List.range n).all (fun p =>
      effectAfter n g enabled broken p == providerCallable n g enabled broken p &&
      effectAfter n g enabled broken p == closureOk g enabled broken n p))))

theorem channels_agree_and_effects_iff_closure : (List.range 4).all check = true := by native_decide

/-- The gap: plugin 1 depends on plugin 0, which is disabled. Plugin 1's
    providers were withheld while its effects still installed. -/
theorem effects_outran_providers :
    let deps : Graph := fun p => if p = 1 then [0] else []
    effectBefore [false, true] 1 = true ∧ providerCallable 2 deps [false, true] [false, false] 1 = false := by
  decide

/-- A plugin that failed to load stays enabled by the operator's flag but is
    broken; before, its effects installed. -/
theorem failed_load_effects :
    effectBefore [true] 0 = true ∧ effectAfter 1 (fun _ => []) [true] [true] 0 = false := by
  decide

end EffectHealth
end SyrusModel
