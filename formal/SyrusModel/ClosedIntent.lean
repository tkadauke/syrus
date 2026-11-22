/-!
# A closed Job never keeps a requested WorkIntent that nothing can finish

Coverage item `closed-job-open-intent`. Two writers end a Job-scoped
WorkIntent:

* `Job#cancel_stale_work_intents_after_close`, at close: cancels every
  requested or waiting intent *with no active unit*, and leaves one with an
  active unit to that unit;
* `WorkIntents::TerminalUnitSync`, when a unit ends with no active sibling:
  - satisfied on success;
  - failed on failure;
  - cancelled when the cancel reason says the work is over
    (`SUPERSEDING_CANCEL_REASONS`);
  - otherwise left requested for a relaunch, e.g. an Epic-conflict victim.

Between them they missed a case. A Job closes while its unit is still
active, and the unit is later cancelled for a relaunch-keeping reason. Nothing
relaunches work on a closed Job, so the intent stayed requested forever.
Production had one: closed seconds before its unit was cancelled for
`epic_wide_workflow_active` (`before_strands`).

After the fix, the sync also cancels on any cancellation once the Job is
closed. Over every sequence of up to six events, with up to two units, the
invariant holds in every reachable state (`after_closed_intents_have_owner`):
a closed Job's open intent always has an active unit that will end it.

Close is modelled as leaving active units alone. That is the worst case: the
close paths that cancel them do so with `job_closed`, which is an ending
reason.
-/

namespace SyrusModel
namespace ClosedIntent

inductive Outcome where
  | succeed
  | fail
  /-- A reason in `SUPERSEDING_CANCEL_REASONS`: the work is over. -/
  | cancelEnding
  /-- Any other reason; the intent is normally kept for a relaunch. -/
  | cancelRelaunch
deriving DecidableEq, Repr

structure S where
  closed : Bool
  intentOpen : Bool
  /-- Each unit: `true` while active. -/
  units : List Bool
deriving DecidableEq, Repr

inductive Ev where
  | close
  /-- A new unit for the intent. Launches are refused on a closed Job, and a
      unit re-requests a terminal intent (WorkUnit reentry). -/
  | start
  | finish (i : Nat) (o : Outcome)
deriving DecidableEq, Repr

def anyActive (us : List Bool) : Bool := us.any id

def setInactive : List Bool → Nat → List Bool
  | [], _ => []
  | _ :: us, 0 => false :: us
  | u :: us, k + 1 => u :: setInactive us k

/-- What the sync does with the intent once the last active unit ended. -/
def syncEnds (fixed : Bool) (closed : Bool) : Outcome → Bool
  | .succeed => true
  | .fail => true
  | .cancelEnding => true
  | .cancelRelaunch => fixed && closed

def step (fixed : Bool) (s : S) : Ev → S
  | .close =>
    if s.closed then s
    else { s with closed := true, intentOpen := s.intentOpen && anyActive s.units }
  | .start =>
    if s.closed || s.units.length ≥ 2 then s
    else { s with intentOpen := true, units := s.units ++ [true] }
  | .finish i o =>
    if s.units.getD i false then
      let units := setInactive s.units i
      let ends := s.intentOpen && !anyActive units && syncEnds fixed s.closed o
      { s with units, intentOpen := s.intentOpen && !ends }
    else s

def inv (s : S) : Bool := !(s.closed && s.intentOpen) || anyActive s.units

def outcomes : List Outcome := [.succeed, .fail, .cancelEnding, .cancelRelaunch]

def events : List Ev :=
  [.close, .start] ++ ([0, 1].flatMap fun i => outcomes.map (.finish i))

/-- The intent exists with its first unit, on an open Job. -/
def init : S := ⟨false, true, [true]⟩

def reachable (fixed : Bool) : Nat → List S
  | 0 => [init]
  | k + 1 =>
    let prev := reachable fixed k
    prev ++ prev.flatMap (fun s => events.map (step fixed s))

def check (fixed : Bool) (depth : Nat) : Bool := (reachable fixed depth).all inv

theorem after_closed_intents_have_owner : check true 6 = true := by native_decide

/-- Before: close while the unit runs, then cancel it for a relaunch-keeping
    reason. The Job is closed, the intent is open, and no unit owns it. -/
theorem before_strands :
    let s := [Ev.close, .finish 0 .cancelRelaunch].foldl (step false) init
    s = ⟨true, true, [false]⟩ ∧ inv s = false ∧
      [Ev.close, .finish 0 .cancelRelaunch].foldl (step true) init = ⟨true, false, [false]⟩ := by
  decide

/-- The fix does not end an Epic-conflict victim's intent while its Job is
    open: the relaunch still finds it requested. -/
theorem open_job_keeps_relaunch :
    [Ev.finish 0 .cancelRelaunch].foldl (step true) init = ⟨false, true, [false]⟩ := by
  decide

end ClosedIntent
end SyrusModel
