/-!
# DOC-44 plugin host: an unreadable enablement answer never enables a plugin

NY13 (decided): "We should not treat installed plugins as enabled. This is
potentially destructive. We need to retry until we have a straight answer."

`Syrus::PluginRegistry` reads plugin enablement from `PluginRecord`. On any
database error, `providers_for`, `all_plugins`, `health` and
`credential_types` answered as if every installed plugin were enabled, and
`beta_mode_enabled?` answered `true`. During a lock timeout or a dropped
connection, a plugin the operator had disabled was callable: an execution
backend, an approval provider (`blip_enables_disabled`). The Installer
answered "install everything" the same way.

After the fix, one read (`enablement_records`) decides every case:

* the database or the `plugin_records` table does not exist: the declared
  defaults, which are exactly what the records will say once created;
* an asset build (`SECRET_KEY_BASE_DUMMY`), with no instance and no
  database: every plugin, so their assets build;
* any other error: retried, then `EnablementUnavailable`, so the caller fails
  instead of answering.

The Installer resolves the set before disposing anything, and on an
unavailable answer keeps what is installed.

Over every outcome sequence of up to three read attempts, every combination
of two plugins' declared defaults and operator records, and both build modes:
outside an asset build, the answer is exactly what the first non-transient
read within the attempt budget says (records, or the defaults for a missing
database or table), or unavailable, and never "every installed plugin"
(`never_enables_disabled_and_answers_when_readable`).
-/

namespace SyrusModel
namespace EnablementRead

/-- One read attempt's outcome. -/
inductive Read where
  | ok
  | noDatabase
  | noTable
  | transient
deriving DecidableEq, Repr

inductive Answer where
  | enabled (set : List Bool)
  | unavailable
deriving DecidableEq, Repr

def attempts : Nat := 3

/-- After: defaults for a missing database or table, records when read,
    unavailable after `attempts` transient failures. -/
def readAfter (buildTime : Bool) (defaults records : List Bool) : List Read → Nat → Answer
  | _, 0 => .unavailable
  | [], _ => .unavailable
  | r :: rs, k + 1 =>
    if buildTime then .enabled (defaults.map (fun _ => true))
    else match r with
      | .ok => .enabled records
      | .noDatabase => .enabled defaults
      | .noTable => .enabled defaults
      | .transient => readAfter buildTime defaults records rs k

/-- Before: any error at all answered "every installed plugin is enabled". -/
def readBefore (defaults records : List Bool) : List Read → Answer
  | .ok :: _ => .enabled records
  | _ => .enabled (defaults.map (fun _ => true))

def reads : List Read := [.ok, .noDatabase, .noTable, .transient]

def seqs : Nat → List (List Read)
  | 0 => [[]]
  | k + 1 => [] :: (seqs k).flatMap (fun s => reads.map (fun r => r :: s))

def bools2 : List (List Bool) := [[true, true], [true, false], [false, true], [false, false]]

/-- The specification, stated without the retry loop: the first read within
    the attempt budget that is not transient decides; if every attempt was
    transient, there is no answer. -/
def decided (defaults records : List Bool) (rs : List Read) : Answer :=
  match (rs.take attempts).find? (· != .transient) with
  | some .ok => .enabled records
  | some .noDatabase => .enabled defaults
  | some .noTable => .enabled defaults
  | _ => .unavailable

/-- Never "every installed plugin": the answer is the records, the defaults,
    or nothing. -/
def neverAllInstalled (defaults records : List Bool) : Answer → Bool
  | .unavailable => true
  | .enabled set => set == records || set == defaults

def check : Bool :=
  (seqs attempts).all (fun rs => bools2.all (fun dflt => bools2.all (fun rec =>
    let answer := readAfter false dflt rec rs attempts
    answer == decided dflt rec rs && neverAllInstalled dflt rec answer)))

theorem never_enables_disabled_and_answers_when_readable : check = true := by native_decide

/-- Before: one transient error enabled a plugin the operator had disabled. -/
theorem blip_enables_disabled :
    readBefore [true, true] [true, false] [.transient] = .enabled [true, true] ∧
      readAfter false [true, true] [true, false] [.transient, .transient, .transient] attempts = .unavailable ∧
      readAfter false [true, true] [true, false] [.transient, .ok] attempts = .enabled [true, false] := by
  decide

end EnablementRead
end SyrusModel
