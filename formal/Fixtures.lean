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

def workflowState : EpicTurn.W → String
  | .queued => "queued"
  | .running => "running"
  | .failed => "failed"
  | .done => "succeeded"

/-- `StepDispatcher.epic_sibling_blocking?` as `!EpicTurn.mayStart`, for a
linear Epic of three children in creation order, every state of each child's
implementation Workflow, and every queued candidate. No Job dependencies: the
Ruby's skip of a queued child that waits on a queued sibling is not modelled,
and the "at most one running" proof holds for any single winner. -/
def epicTurn : String :=
  let states : List EpicTurn.W := [.queued, .running, .failed, .done]
  let cases := states.flatMap fun a => states.flatMap fun b => states.flatMap fun c =>
    let s : Fin 3 → EpicTurn.W := fun i => if i.val = 0 then a else if i.val = 1 then b else c
    (List.finRange 3).filterMap fun i =>
      if s i = .queued then
        some ("    {\"states\": [" ++ ", ".intercalate ([a, b, c].map (jsonString ∘ workflowState)) ++
          "], \"candidate\": " ++ toString i.val ++ ", \"may_start\": " ++ jsonBool (EpicTurn.mayStart s i) ++ "}")
      else none
  "{\n  \"model\": \"EpicTurn.mayStart\",\n  \"cases\": [\n" ++ ",\n".intercalate cases ++ "\n  ]\n}\n"

/-- `WorkEngine::Reconciler#orphaned_queue_job?` as `QueueExecution.orphaned`,
over every combination of the five SolidQueue execution flags and the job's age. -/
def orphanedQueueJob : String :=
  let bools := [true, false]
  let cases := bools.flatMap fun r => bools.flatMap fun c => bools.flatMap fun s => bools.flatMap fun b => bools.flatMap fun f =>
    bools.map fun old =>
    let flags : QueueExecution.Flags := ⟨r, c, s, b, f⟩
    "    {\"ready\": " ++ jsonBool r ++ ", \"claimed\": " ++ jsonBool c ++ ", \"scheduled\": " ++ jsonBool s ++
      ", \"blocked\": " ++ jsonBool b ++ ", \"failed\": " ++ jsonBool f ++ ", \"old\": " ++ jsonBool old ++
      ", \"orphaned\": " ++ jsonBool (QueueExecution.orphaned flags old) ++ "}"
  "{\n  \"model\": \"QueueExecution.orphaned\",\n  \"cases\": [\n" ++ ",\n".intercalate cases ++ "\n  ]\n}\n"

/-- `Workflows::ImmutableReviewHeadBarrier.satisfied_for?` for one required
review, as `ReviewBarrier.satisfied`, over every combination of its evidence. -/
def reviewBarrier : String :=
  let cases := ReviewBarrier.allEvidence.map fun e =>
    "    {\"tracked_head\": " ++ jsonBool e.tracked ++ ", \"succeeded\": " ++ jsonBool e.succeeded ++
      ", \"approved\": " ++ jsonBool e.approved ++ ", \"reacted_without_head_change\": " ++ jsonBool e.reactedWithoutHeadChange ++
      ", \"exhausted_for_head\": " ++ jsonBool e.exhaustedForHead ++
      ", \"satisfied\": " ++ jsonBool (ReviewBarrier.satisfied e) ++ "}"
  "{\n  \"model\": \"ReviewBarrier.satisfied\",\n  \"cases\": [\n" ++ ",\n".intercalate cases ++ "\n  ]\n}\n"

/-- The eight Step variants the scan distinguishes: serial or parallel, and
queued-ready, queued-not-ready, running or done. -/
def readyStepVariants : List ReadySet.Step :=
  [ReadySet.K.serial, .parallel].flatMap fun k =>
    [⟨k, .queued, true⟩, ⟨k, .queued, false⟩, ⟨k, .running, false⟩, ⟨k, .done, false⟩]

def readyStepJson (s : ReadySet.Step) : String :=
  let kind := match s.k with | .serial => "serial" | .parallel => "parallel"
  let state := match s.st with | .queued => "queued" | .running => "running" | .done => "succeeded"
  "{\"kind\": " ++ jsonString kind ++ ", \"state\": " ++ jsonString state ++ ", \"ready\": " ++ jsonBool s.ready ++ "}"

/-- `StepDispatcher#distributed_ready_set` as `ReadySet.readySet`, for every
Workflow of three Steps and every cursor (0 scans from the start; a cursor c > 0
is the position after a Step at position c - 1 that just finished). -/
def readySetFixture : String :=
  let workflows := readyStepVariants.flatMap fun a => readyStepVariants.flatMap fun b =>
    readyStepVariants.map fun c => [a, b, c]
  let cases := workflows.flatMap fun l => (List.range 4).map fun cur =>
    "    {\"steps\": [" ++ ", ".intercalate (l.map readyStepJson) ++ "], \"cursor\": " ++ toString cur ++
      ", \"ready_set\": [" ++ ", ".intercalate ((ReadySet.readySet l cur).map toString) ++ "]}"
  "{\n  \"model\": \"ReadySet.readySet\",\n  \"cases\": [\n" ++ ",\n".intercalate cases ++ "\n  ]\n}\n"

def all : List (String × String) :=
  [("auto_approval", autoApproval), ("train_evidence", trainEvidence), ("epic_turn", epicTurn),
   ("orphaned_queue_job", orphanedQueueJob), ("review_barrier", reviewBarrier), ("ready_set", readySetFixture)]

end Fixtures

def main (args : List String) : IO UInt32 := do
  match args with
  | [name] =>
    match Fixtures.all.lookup name with
    | some fixture => IO.print fixture; return 0
    | none => IO.eprintln s!"unknown fixture {name}; known: {Fixtures.all.map (·.1)}"; return 1
  | [] => IO.println (" ".intercalate (Fixtures.all.map (·.1))); return 0
  | _ => IO.eprintln "usage: syrus_fixtures [name]"; return 1
