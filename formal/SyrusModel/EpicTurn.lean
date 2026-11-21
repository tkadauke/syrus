/-!
# Linear Epics: one child implements at a time

`StepDispatcher.epic_sibling_blocking?` gives a linear Epic's implementation
turn to a running sibling, else to the oldest queued one. Two ways around it:

1. **Bypass.** The rule runs only in `start_workflow`. A step retry
   (`RetryFailedStepEnqueuer`) reopens a *failed* implementation Workflow and
   creates its Run directly. A failed sibling does not hold the turn, so the
   next sibling may already be running.
2. **Race.** The rule reads "is a sibling running?" and "who is the oldest
   queued?" in two queries. A sibling whose RunJob flips it from queued to
   running between them is in neither answer.

Workflows (one per child, ordered by creation) are `queued`, `running`,
`failed` or `done`.
-/

namespace SyrusModel
namespace EpicTurn

inductive W where | queued | running | failed | done deriving DecidableEq, Repr

variable {n : Nat}

def upd (f : Fin n → W) (i : Fin n) (v : W) : Fin n → W := fun j => if j = i then v else f j

def running (s : Fin n → W) : Nat := ((List.finRange n).filter fun i => s i = .running).length

/-- The oldest queued Workflow (lowest index), from one snapshot. -/
def oldestQueued (s : Fin n → W) : Option (Fin n) := (List.finRange n).find? fun i => s i = .queued

/-- The rule evaluated on a single snapshot. -/
def mayStart (s : Fin n → W) (i : Fin n) : Bool :=
  !((List.finRange n).any fun j => j != i && s j = .running) &&
    (match oldestQueued s with | some w => w == i | none => true)

/-- `start_workflow` with the rule evaluated atomically. -/
def start (s : Fin n → W) (i : Fin n) : Fin n → W :=
  if s i = .queued && mayStart s i then upd s i .running else s

/-- Old step retry: reopen a failed Workflow and run it, no rule. -/
def retryUnguarded (s : Fin n → W) (i : Fin n) : Fin n → W :=
  if s i = .failed then upd s i .running else s

/-- Fixed step retry: the rule is applied where every Run is created. -/
def retryGuarded (s : Fin n → W) (i : Fin n) : Fin n → W :=
  if s i = .failed && !((List.finRange n).any fun j => j != i && s j = .running) then upd s i .running else s

def fail (s : Fin n → W) (i : Fin n) : Fin n → W := if s i = .running then upd s i .failed else s
def finish (s : Fin n → W) (i : Fin n) : Fin n → W := if s i = .running then upd s i .done else s

def OneRunning (s : Fin n → W) : Bool := running s ≤ 1

/-! ## Counterexamples -/

/-- Bypass: A fails, B takes the turn, A's failed step is retried. -/
theorem retry_bypass :
    let s0 : Fin 2 → W := fun _ => .queued
    let s := retryUnguarded (start (fail (start s0 0) 0) 1) 0
    OneRunning s = false := by decide

/-- Race: B reads "nobody running" while A is still queued; A's RunJob then
    flips A to running; B reads the queued list, which no longer has A, and
    takes the turn. -/
theorem two_query_race :
    let s0 : Fin 2 → W := fun _ => .queued
    -- B's first query: is any sibling running?
    let noneRunning := !((List.finRange 2).any fun j => j != 1 && s0 j = .running)
    -- A was the winner and its RunJob starts now.
    let s1 := upd s0 0 .running
    -- B's second query sees the queued list without A.
    let bWins := (match oldestQueued s1 with | some w => w == 1 | none => true)
    noneRunning = true ∧ bWins = true ∧ OneRunning (upd s1 1 .running) = false := by decide

/-! ## With the fix, every reachable state has at most one running child -/

inductive Op (n : Nat) where
  | start (i : Fin n) | retry (i : Fin n) | fail (i : Fin n) | finish (i : Fin n)

def apply (s : Fin n → W) : Op n → (Fin n → W)
  | .start i => start s i
  | .retry i => retryGuarded s i
  | .fail i => fail s i
  | .finish i => finish s i

def allStates : (k : Nat) → List (Fin k → W)
  | 0 => [fun i => i.elim0]
  | k + 1 => (allStates k).flatMap fun f =>
      [W.queued, W.running, W.failed, W.done].map fun w =>
        fun i : Fin (k + 1) => if h : i.val = 0 then w else f ⟨i.val - 1, by omega⟩

def allOps (k : Nat) : List (Op k) :=
  (List.finRange k).flatMap fun i => [Op.start i, Op.retry i, Op.fail i, Op.finish i]

/-- Every operation preserves "at most one running child", for every Epic of
    up to 4 children and every state. -/
def preserved (k : Nat) : Bool :=
  (allStates k).all fun s => !(OneRunning s) || (allOps k).all fun o => OneRunning (apply s o)

theorem fixed_preserves_one_running : preserved 4 = true := by native_decide

end EpicTurn
end SyrusModel
