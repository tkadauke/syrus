/-!
# DOC-44 plugin host: plugin CLI command collisions fail deterministically

DOC-44: "Plugin CLI command collisions fail deterministically."

The Go CLI (`registerPluginCommands`) walks the server's catalog in order and
mounts each command at its bare path unless something already sits there: a
command at that path, or a group created for a longer path below it. A
command is reachable exactly when it was mounted. The server sorted the
catalog by plugin name, then path. So when two plugins declared the same path,
or one plugin's path was a prefix of another's, the plugin that sorted first
kept it and the other's command silently vanished. Renaming a plugin flips
which one survives (`owner_follows_names`).

After the fix (`PluginCliCommands.catalog` drops every command in a
cross-plugin collision, `CliCommand.collisions`, and `PluginHealth` warns
about each one), the catalog holds no such pair. Then, for every set of
commands over two plugins and paths of up to two words from a two-word
vocabulary, every offered command is mounted, whether the plugins come in
sorted order or reversed (`all_offered_reachable`). Within a plugin, paths
stay sorted, so its `docs` mounts before its `docs list`. Built-in commands
are mounted first and always win, which the Go test
`TestCompiledCommandWinsOverCatalogCollision` pins.
-/

namespace SyrusModel
namespace CliCollisions

structure Cmd where
  plugin : Nat
  path : List Nat
deriving DecidableEq, Repr

def isPrefix : List Nat → List Nat → Bool
  | [], _ => true
  | _ :: _, [] => false
  | a :: as, b :: bs => a == b && isPrefix as bs

/-- Something already sits at `c`'s path: a mounted command there, or a
    group made for a longer mounted path below it. -/
def blocked (mounted : List Cmd) (c : Cmd) : Bool :=
  mounted.any (fun d => isPrefix c.path d.path)

def mount (cmds : List Cmd) : List Cmd :=
  cmds.foldl (fun mounted c => if blocked mounted c then mounted else mounted ++ [c]) []

def collides (a b : Cmd) : Bool :=
  a.plugin != b.plugin && (isPrefix a.path b.path || isPrefix b.path a.path)

/-- The fix: withhold every command that collides with another plugin's. -/
def offered (cmds : List Cmd) : List Cmd :=
  cmds.filter (fun c => !cmds.any (collides c))

def paths : List (List Nat) := [[0], [1], [0, 0], [0, 1], [1, 0], [1, 1]]

/-- Catalog order within a plugin: shorter paths, so prefixes, first. -/
def allCmds : List Cmd :=
  [0, 1].flatMap (fun p => paths.map (fun path => ⟨p, path⟩))

def subsets : List Cmd → List (List Cmd)
  | [] => [[]]
  | c :: cs => (subsets cs).flatMap (fun s => [c :: s, s])

def byPlugin (cmds : List Cmd) (p : Nat) : List Cmd := cmds.filter (·.plugin == p)

def allMounted (order : List Cmd) : Bool :=
  order.all (fun c => (mount order).contains c)

def check : Bool :=
  (subsets allCmds).all (fun s =>
    let o := offered s
    allMounted (byPlugin o 0 ++ byPlugin o 1) && allMounted (byPlugin o 1 ++ byPlugin o 0))

theorem all_offered_reachable : check = true := by native_decide

/-- Before: two plugins declare `docs`; whichever sorts first owns it, and a
    rename flips the owner. -/
theorem owner_follows_names :
    mount [⟨0, [0]⟩, ⟨1, [0]⟩] = [⟨0, [0]⟩] ∧ mount [⟨1, [0]⟩, ⟨0, [0]⟩] = [⟨1, [0]⟩] := by
  decide

/-- Before: plugin 1's `docs list` sorting first turns `docs` into a group, so
    plugin 0's runnable `docs` vanishes. -/
theorem prefix_vanishes :
    mount [⟨1, [0, 1]⟩, ⟨0, [0]⟩] = [⟨1, [0, 1]⟩] := by
  decide

end CliCollisions
end SyrusModel
