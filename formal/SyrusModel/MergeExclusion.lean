/-!
# A landing merges onto the base it just checked (Lead L15, NY41)

`MergeLock` serializes the last landing sequence on one branch: check that the
validated base is still the branch head, then merge. GitHub's `expected_sha`
guards the PR head, not the base, so this is only sound if nothing else writes
the branch between the check and the merge.

Writers are landing lanes and publishes (hotfix sync, promotion). A trace is a
list of events by writers. A writer may write only while it holds the branch's
lock if it is `locked`. This file proves:

* `no_write_between_check_and_merge`: when every writer is locked, no other
  writer's write falls between a lane's check and its merge;
* `unlocked_writer_breaks_it`: one unlocked writer is enough to put a write
  there, which is the gap NY41 closes for hotfix sync and promotion.
-/

namespace SyrusModel
namespace MergeExclusion

inductive Event
  | acquire (w : Nat)
  | release (w : Nat)
  | check (w : Nat)   -- a lane reads the branch head
  | write (w : Nat)   -- a merge or push moves the branch
  deriving DecidableEq, Repr

/-- Replay a trace, tracking the lock holder; `false` if a locked writer writes
or checks without holding the lock, or the lock is taken while held. -/
def valid (locked : Nat → Bool) : Option Nat → List Event → Bool
  | _, [] => true
  | none, .acquire w :: rest => valid locked (some w) rest
  | some _, .acquire _ :: _ => false
  | some h, .release w :: rest => h == w && valid locked none rest
  | none, .release _ :: _ => false
  | holder, .check w :: rest => holder == some w && valid locked holder rest
  | holder, .write w :: rest => (!locked w || holder == some w) && valid locked holder rest

/-- After a `check` by lane `w`, the events up to `w`'s merge (its next
`write`) or until it gives the lock up without merging (its `release`). -/
def windowAfterCheck (w : Nat) : List Event → List Event
  | [] => []
  | .write v :: rest => if v == w then [] else .write v :: windowAfterCheck w rest
  | .release v :: rest => if v == w then [] else .release v :: windowAfterCheck w rest
  | e :: rest => e :: windowAfterCheck w rest

/-- Some other writer writes inside `w`'s check-to-merge window. -/
def intruded (w : Nat) : List Event → Bool
  | [] => false
  | .check v :: rest =>
    (v == w && (windowAfterCheck w rest).any (fun e => match e with | .write u => u != w | _ => false))
      || intruded w rest
  | _ :: rest => intruded w rest

/-- Two lanes and one publisher, all locked; every valid trace of up to five
events is free of intrusion. -/
def writers : List Nat := [0, 1, 2]

def events : List Event :=
  writers.flatMap fun w => [.acquire w, .release w, .check w, .write w]

def traces : Nat → List (List Event)
  | 0 => [[]]
  | n + 1 => [] :: (traces n).flatMap fun t => events.map (· :: t)

theorem no_write_between_check_and_merge :
    (traces 5).all (fun t => !valid (fun _ => true) none t || writers.all (fun w => !intruded w t)) = true := by
  native_decide

/-- Publisher 2 unlocked: lane 0 checks, the publisher writes, lane 0 merges. -/
theorem unlocked_writer_breaks_it :
    let t := [Event.acquire 0, .check 0, .write 2, .write 0, .release 0]
    valid (fun w => w != 2) none t = true ∧ intruded 0 t = true := by
  decide

end MergeExclusion
end SyrusModel
