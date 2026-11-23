import SyrusModel

/-!
# Conformance fixtures (formal/INTEGRATION.md, layer 3)

For the pure decision functions, the model's answer over every small input,
written as JSON to `formal/fixtures/<name>.json`. A Ruby spec under
`spec/formal/` runs the real method on the same inputs and compares, which
closes the gap a proof alone cannot: that the model is the code.

`lake exe syrus_fixtures <name>` prints one fixture; formal CI regenerates
every fixture and fails if a committed one differs.
-/

open SyrusModel

namespace Fixtures

def jsonBool (b : Bool) : String := if b then "true" else "false"
def jsonString (s : String) : String := "\"" ++ s ++ "\""

def jobState : AutoApproval.J → String
  | .running => "running"
  | .implemented => "implemented"
  | .approved => "approved"
  | .failed => "failed"

/-- `AutoApprovalRule#approve_after_grader_success!` as `AutoApproval.approveNew`:
the Job's state afterwards, for every Job state with and without a PR. -/
def autoApproval : String :=
  let states := [AutoApproval.J.running, .implemented, .approved, .failed]
  let cases := states.flatMap fun job => [true, false].map fun pr =>
    let after := AutoApproval.approveNew ⟨job, pr, true, true⟩
    "    {\"job_state\": " ++ jsonString (jobState job) ++ ", \"pull_request\": " ++ jsonBool pr ++
      ", \"job_state_after\": " ++ jsonString (jobState after.job) ++ "}"
  "{\n  \"model\": \"AutoApproval.approveNew\",\n  \"cases\": [\n" ++ ",\n".intercalate cases ++ "\n  ]\n}\n"

def ancestry : TrainEvidence.Anc → String
  | .ancestor => "ancestor"
  | .notAncestor => "not_ancestor"
  | .indeterminate => "indeterminate"

/-- `Steps::MergeTrainLand#member_landed?` as `TrainEvidence.landed`, over every
combination of its evidence inputs. -/
def trainEvidence : String :=
  let cases := TrainEvidence.allMembers.map fun m =>
    "    {\"recorded\": " ++ jsonBool m.recorded ++ ", \"ancestry\": " ++ jsonString (ancestry m.anc) ++
      ", \"recent_build\": " ++ jsonBool m.recentBuild ++ ", \"patch_equivalent\": " ++ jsonBool m.patchEquivalent ++
      ", \"rebased_into_integration\": " ++ jsonBool m.rebasedIntoIntegration ++
      ", \"landed\": " ++ jsonBool (TrainEvidence.landed m) ++ "}"
  "{\n  \"model\": \"TrainEvidence.landed\",\n  \"cases\": [\n" ++ ",\n".intercalate cases ++ "\n  ]\n}\n"

def all : List (String × String) := [("auto_approval", autoApproval), ("train_evidence", trainEvidence)]

end Fixtures

def main (args : List String) : IO UInt32 := do
  match args with
  | [name] =>
    match Fixtures.all.lookup name with
    | some fixture => IO.print fixture; return 0
    | none => IO.eprintln s!"unknown fixture {name}; known: {Fixtures.all.map (·.1)}"; return 1
  | [] => IO.println (" ".intercalate (Fixtures.all.map (·.1))); return 0
  | _ => IO.eprintln "usage: syrus_fixtures [name]"; return 1
