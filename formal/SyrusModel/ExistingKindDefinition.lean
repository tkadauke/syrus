/-!
# DOC-44 plugin host: in-flight work stays cancellable, new work still needs a healthy owner

NY14 (decided): keep the kind metadata of every installed plugin resolvable for
existing rows, and let only new work require an enabled and healthy owner.

When a plugin is disabled, or turns unhealthy after boot, its kinds leave the
registry. `Workflow#work_definition` resolved through that registry, and the
cancel cascade asks the definition questions, so cancelling an in-flight
Workflow of such a kind raised `WorkDefinitions::UnknownKind`
(`cancel_raised`). F61 had kept the rows saveable, but they still could not
be cancelled.

After the fix there are two lookups:

* `WorkDefinitions.for`, used by every launch path, returns a definition only
  for a registered kind, meaning the owner is enabled and healthy;
* `WorkDefinitions.for_existing`, used by `Workflow#work_definition` for rows
  that already exist, falls back to the installed plugin's own definition,
  whatever its state, and otherwise to the neutral `Unavailable`.

Over every combination of kind ownership (built-in, installed plugin, plugin
that is not installed) and owner state (enabled and healthy or not):

- an existing row always gets an answer (`existing_always_answers`);
- a launch gets one exactly when the kind is built-in or its owner is enabled
  and healthy (`launch_needs_healthy_owner`);
- `Unavailable` is never what a launch receives (`unavailable_never_launches`).
-/

namespace SyrusModel
namespace ExistingKindDefinition

inductive Owner where
  | builtIn
  | installed (healthy : Bool)
  | notInstalled
deriving DecidableEq, Repr

inductive Definition where
  | own
  | unavailable
deriving DecidableEq, Repr

def registered : Owner → Bool
  | .builtIn => true
  | .installed healthy => healthy
  | .notInstalled => false

/-- `WorkDefinitions.for`: launches. -/
def forLaunch (o : Owner) : Option Definition := if registered o then some .own else none

/-- `WorkDefinitions.for_existing`: existing rows. -/
def forExisting : Owner → Definition
  | .builtIn => .own
  | .installed _ => .own
  | .notInstalled => .unavailable

/-- Before: existing rows used the launch lookup. -/
def existingBefore (o : Owner) : Option Definition := forLaunch o

def owners : List Owner := [.builtIn, .installed true, .installed false, .notInstalled]

theorem existing_always_answers : owners.all (fun o => forExisting o == .own || forExisting o == .unavailable) = true := by
  decide

theorem launch_needs_healthy_owner :
    owners.all (fun o => (forLaunch o).isSome == registered o) = true := by
  decide

theorem unavailable_never_launches : owners.all (fun o => forLaunch o != some .unavailable) = true := by
  decide

theorem cancel_raised :
    existingBefore (.installed false) = none ∧ forExisting (.installed false) = .own := by
  decide

end ExistingKindDefinition
end SyrusModel
