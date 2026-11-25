/-!
# The distributed ready set and the serial barrier

`StepDispatcher#distributed_ready_set` decides which Steps start next when the
distributed workflow DAG is on. Parallel Steps (graders, preflight graders,
multisect evaluation — `IMMUTABLE_SOURCE_CHECKOUT`) read an immutable snapshot;
every other Step is *serial*: it shares the mutable workspace, and every Step
that moves HEAD (`implement`, `respond`, `format`, …) is serial.

This file mirrors the scan exactly: starting at the position after the Step
that just finished, walk the active (queued/running) Steps in position order;
a running parallel Step is passed over, a running serial Step stops the scan;
a queued Step that is not ready stops it if serial and is passed over if
parallel; a ready parallel Step is collected; the first ready serial Step is
taken only if no parallel Step was collected.

**Invariant `SerialBarrier`:** no Step positioned after an unfinished serial
Step has started. Consequences: at most one serial Step runs at a time, and
nothing after a running HEAD-moving Step is active — so a Run downstream of a
required review can only become stale while still *queued*, where `RunJob`
cancels it at start (`running_run_before_required_review_barrier` needs a
violation of this invariant).

Checked exhaustively (by `native_decide`) for every Workflow of up to 5 Steps,
every readiness assignment, and every legal cursor. Inserted Steps (loop
iterations, Try branches, review re-materialization, grader fan-out) are
modelled at the end: safe after a finished serial Step, and after a finished
parallel Step only if nothing after it has started; skipping a queued Step
keeps the barrier too.
-/

namespace SyrusModel
namespace ReadySet

inductive K where | serial | parallel deriving DecidableEq, Repr
inductive St where | queued | running | done deriving DecidableEq, Repr

structure Step where
  k : K
  st : St
  ready : Bool
  deriving DecidableEq, Repr

/-- The scan cur index `i`, accumulating collected parallel indices. -/
def scanAux : List Step → Nat → List Nat → Option Nat
  | [], _, acc => if acc.isEmpty then none else none
  | s :: rest, i, acc =>
    match s.st with
    | .done => scanAux rest (i + 1) acc
    | .running => if s.k = .parallel then scanAux rest (i + 1) acc else none
    | .queued =>
      if !s.ready then (if s.k = .parallel then scanAux rest (i + 1) acc else none)
      else if s.k = .parallel then scanAux rest (i + 1) (i :: acc)
      else if acc.isEmpty then some i else none

/-- Parallel Steps collected by the scan (only those before the stopping point). -/
def parallelsAux : List Step → Nat → List Nat
  | [], _ => []
  | s :: rest, i =>
    match s.st with
    | .done => parallelsAux rest (i + 1)
    | .running => if s.k = .parallel then parallelsAux rest (i + 1) else []
    | .queued =>
      if !s.ready then (if s.k = .parallel then parallelsAux rest (i + 1) else [])
      else if s.k = .parallel then i :: parallelsAux rest (i + 1) else []

/-- `distributed_ready_set` scanning positions `≥ cur`. -/
def readySet (l : List Step) (cur : Nat) : List Nat :=
  let tail := l.drop cur
  let ps := parallelsAux tail cur
  if ps.isEmpty then (scanAux tail cur []).toList else ps

def startAll (l : List Step) (ix : List Nat) : List Step :=
  l.mapIdx (fun i s => if ix.contains i then { s with st := .running } else s)

def unfinishedSerial (s : Step) : Bool := s.k = .serial && s.st != .done

/-- No Step after an unfinished serial Step has started. -/
def serialBarrier (l : List Step) : Bool :=
  (List.range l.length).all fun i =>
    (List.range l.length).all fun j =>
      !(i < j && (l.getD i ⟨.serial, .done, false⟩ |> unfinishedSerial)) ||
        (l.getD j ⟨.serial, .done, false⟩).st = .queued

/-- The cursor is legal: every serial Step before it is finished (the cursor is
    one past the Step that just finished, which by the invariant cannot lie
    beyond the first unfinished serial Step). -/
def cursorOk (l : List Step) (cur : Nat) : Bool :=
  (List.range (min cur l.length)).all fun i => !unfinishedSerial (l.getD i ⟨.serial, .done, false⟩)

def runningSerials (l : List Step) : Nat := (l.filter fun s => s.k = .serial && s.st = .running).length

/-! ## Exhaustive check -/

def allSteps : List Step :=
  [K.serial, K.parallel].flatMap fun k =>
    [St.queued, St.running, St.done].flatMap fun st =>
      [true, false].map fun r => ⟨k, st, r⟩

/-- Every Workflow of exactly `n` Steps. -/
def exactly : Nat → List (List Step)
  | 0 => [[]]
  | n + 1 => (exactly n).flatMap fun l => allSteps.map fun s => s :: l

/-- Every Workflow of at most `n` Steps. -/
def allLists (n : Nat) : List (List Step) := (List.range (n + 1)).flatMap exactly

def preserves (n : Nat) : Bool :=
  (allLists n).all fun l =>
    (List.range (l.length + 1)).all fun cur =>
      !(serialBarrier l && cursorOk l cur) || serialBarrier (startAll l (readySet l cur))

def oneSerialRunning (n : Nat) : Bool :=
  (allLists n).all fun l => !serialBarrier l || runningSerials l ≤ 1

/-- Starting whatever the ready set picks never breaks the serial barrier. -/
theorem readySet_preserves_barrier : preserves 5 = true := by native_decide

/-- Under the barrier, at most one serial Step runs at a time. -/
theorem barrier_one_serial : oneSerialRunning 5 = true := by native_decide

/-- The cursor matters: scanning cur past an unfinished serial Step (the
    position filter `position > from_step.position`) would start a second
    serial Step alongside it. -/
theorem cursor_needed :
    let l : List Step := [⟨.serial, .running, true⟩, ⟨.serial, .queued, true⟩]
    serialBarrier l = true ∧ cursorOk l 1 = false ∧ serialBarrier (startAll l (readySet l 1)) = false := by
  native_decide

/-! ## Inserted Steps

Loop iterations (`enqueue_next_loop_iteration!`), Try failure branches
(`enqueue_try_failure_branch!`), review re-materialization
(`ImmutableReviewHeadBarrier.refresh_required_reviews!`) and grader fan-out all
insert new, queued Steps directly after the Step that just finished, shifting
later positions while keeping their relative order. -/

/-- Insert queued Steps after position `p`. -/
def insertAfter (l : List Step) (p : Nat) (new : List Step) : List Step :=
  l.take (p + 1) ++ new.map (fun s => { s with st := .queued }) ++ l.drop (p + 1)

def finishAt (l : List Step) (p : Nat) : List Step :=
  l.mapIdx (fun i s => if i = p then { s with st := .done } else s)

/-- Everything after `p` is still queued. -/
def restQueued (l : List Step) (p : Nat) : Bool := (l.drop (p + 1)).all (·.st = .queued)

def smallInserts : List (List Step) := [[]] ++ allSteps.map ([·]) ++ (allSteps.flatMap fun a => allSteps.map fun b => [a, b])

/-- 1. Inserting after a finished Step whose successors are all still queued
    keeps the barrier. -/
def insertSafe (n : Nat) : Bool :=
  (allLists n).all fun l =>
    (List.range l.length).all fun p =>
      !(serialBarrier l && (l.getD p ⟨.serial, .queued, false⟩).st = .done && restQueued l p) ||
        smallInserts.all fun new => serialBarrier (insertAfter l p new)

theorem insert_after_queued_tail_preserves_barrier : insertSafe 4 = true := by native_decide

/-- 2. When the Step that finishes is serial, the barrier held while it was
    unfinished already forced everything after it to be queued, so the
    precondition of (1) holds at every serial insertion point. -/
def serialFinishLeavesQueuedTail (n : Nat) : Bool :=
  (allLists n).all fun l =>
    (List.range l.length).all fun p =>
      !(serialBarrier l && (l.getD p ⟨.parallel, .done, false⟩).k = .serial && (l.getD p ⟨.parallel, .done, false⟩).st = .running) ||
        restQueued (finishAt l p) p

theorem serial_finish_leaves_queued_tail : serialFinishLeavesQueuedTail 5 = true := by native_decide

/-- 3. After a finished *parallel* Step a later parallel Step may already run;
    inserting a serial Step before it breaks the barrier. Every insertion site
    must therefore either follow a serial Step or insert only parallel Steps,
    or know nothing after it has started (Lead L16). -/
theorem serial_insert_after_parallel_breaks :
    let l : List Step := [⟨.parallel, .done, true⟩, ⟨.parallel, .running, true⟩]
    serialBarrier l = true ∧ serialBarrier (insertAfter l 0 [⟨.serial, .queued, true⟩]) = false := by
  native_decide

/-- 4. `skippable_queued_step?` turns a queued Step terminal without starting
    it. The scan only reaches a Step while every serial Step before it is
    finished (it breaks at the first unfinished one, and the cursor is legal),
    and skipping there never breaks the barrier. Without that precondition a
    skip behind an unfinished serial Step would leave a finished Step after it,
    which is why the scan's break matters for skips as well as starts. -/
def skipSafe (n : Nat) : Bool :=
  (allLists n).all fun l =>
    (List.range l.length).all fun p =>
      !(serialBarrier l && cursorOk l p && (l.getD p ⟨.serial, .done, false⟩).st = .queued) ||
        serialBarrier (finishAt l p)

theorem skip_queued_preserves_barrier : skipSafe 5 = true := by native_decide

end ReadySet
end SyrusModel
