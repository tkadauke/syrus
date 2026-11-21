/-!
# DOC-44 plugin host: lifecycle callbacks converge on the plugin's state

DOC-44: "Disable affects new resolution," and "Disabling a provider cannot
strand active work without an explicit recovery path," applied to a plugin's
own effects.

Every enable or disable of a `PluginRecord` enqueues a `PluginLifecycleJob`
(`on_enable` or `on_disable`). `on_enable` registers the plugin's effects, and
`on_disable` runs and drains them. The queue does not order these jobs against
later toggles. So an enable followed quickly by a disable could run `on_enable`
last and leave a disabled plugin holding live effects (`stale_enable_strands`),
and the reverse drained an enabled plugin's effects. `PluginTickJob` likewise
ran `on_tick` for a plugin disabled or degraded after the scheduler enqueued
it.

After the fix, each lifecycle event runs only while it still describes the
plugin's state (`PluginLifecycleJob#stale?`), and a tick only while the plugin
is enabled and healthy. Then, for every sequence of up to four toggles from
either starting state, and every order in which their queued jobs run, the
plugin ends with live effects exactly when it ends enabled (`converges`).
-/

namespace SyrusModel
namespace LifecycleOrder

/-- `true` is an `on_enable` event, `false` an `on_disable`. -/
abbrev Event := Bool

/-- Runs the queued events against the final enablement; returns whether
    effects are live. `guarded` is the fix. -/
def run (guarded : Bool) (enabled : Bool) (live : Bool) : List Event → Bool
  | [] => live
  | e :: es =>
    if guarded && e != enabled then run guarded enabled live es
    else run guarded enabled e es

def permutations : List Event → List (List Event)
  | [] => [[]]
  | x :: xs => (permutations xs).flatMap (fun p =>
      (List.range (p.length + 1)).map (fun i => p.take i ++ [x] ++ p.drop i))

/-- Toggle sequences: each toggle flips the state and enqueues its event. -/
def toggles : Nat → Bool → List (List Event)
  | 0, _ => [[]]
  | k + 1, s => [] :: (toggles k (!s)).map (fun rest => (!s) :: rest)

def finalState (start : Bool) (events : List Event) : Bool := events.getLastD start

def check : Bool :=
  [true, false].all (fun start => (toggles 4 start).all (fun events =>
    let final := finalState start events
    (permutations events).all (fun order => run true final start order == final)))

theorem converges : check = true := by native_decide

/-- Before: enable then disable, with the stale `on_enable` running last,
    leaves the disabled plugin's effects live. -/
theorem stale_enable_strands :
    finalState false [true, false] = false ∧ run false false false [false, true] = true := by
  decide

end LifecycleOrder
end SyrusModel
