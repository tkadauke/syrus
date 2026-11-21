import SyrusModel.Kernel.Json

/-!
# `syrus_oracle`: the DOC-44 executable Lean oracle

Reads one canonical world as JSON on stdin and prints, as JSON:

* `schema_version` and `model_version`;
* `valid`: the executable validity check (`World.validB`, proved sound
  against `World.Valid` by `validB_sound`);
* `issues`: `World.diagnose`;
* `next_state`: `World.reconcile`;
* `next_state_issues`: issues left in the next state (always empty:
  `diagnose_reconcile`), emitted so a consumer can check the claim without
  trusting it.

This is an executable semantics protocol, not a JSON export of proof objects
(DOC-44, "Executable Lean oracle"). An unparsable input exits with status 2
and an `error` object.
-/

open Lean SyrusModel.Kernel

def schemaVersion : Nat := 1
def modelVersion : String := "kernel-0.1"

def report (w : World) : Json :=
  let next := w.reconcile
  Json.mkObj [
    ("schema_version", toJson schemaVersion),
    ("model_version", toJson modelVersion),
    ("valid", toJson w.validB),
    ("issues", toJson w.diagnose),
    ("next_state", toJson next),
    ("next_state_issues", toJson next.diagnose)]

def main : IO UInt32 := do
  let input ← (← IO.getStdin).readToEnd
  match Json.parse input >>= fromJson? (α := World) with
  | .ok w =>
    IO.println (report w).pretty
    return 0
  | .error e =>
    IO.println (Json.mkObj [("schema_version", toJson schemaVersion), ("error", toJson e)]).compress
    return 2
