/-!
# Re-entering a finished WorkUnit keeps "running holds its locks"

Finished WorkUnits are re-entrant by design: a same-attempt retry reuses the
unit (decision D1). The paths back are not uniform. `WorkUnit#block!` and
`#unblock!` set an active state (`blocked`, `queued`) on a unit of any state
without touching its locks, and `AutoRetryBackoff` blocks a *failed* unit on
purpose. So a finished unit whose locks `mark_terminal!` released can be active
again without them.

That does not break lock safety, because the only writer of `state: "running"`
on a WorkUnit is `WorkUnit#mark_running!`, and it runs `ensure_active_locks!`
first: every runtime lock key is held or the call raises `LockConflict`
(`LockAcquire.lean`). Lock-free re-entry stops short of `running`.

**Invariant `RunningHoldsLocks`:** a running unit holds every lock key it
needs. It holds initially and every transition preserves it, from *any* state,
including a re-entered terminal unit (`step_preserves`). Exceptions the code
makes on purpose and this model leaves out: definitions with
`lock_conflicts_enforced?` false, a second unit on the same Workflow (excluded
by `spec/architecture/work_unit_workflow_ownership_spec.rb`), and the
non-blocking main-branch-repair repository lock.
-/

namespace SyrusModel
namespace UnitReentry

inductive US where | queued | blocked | running | terminal deriving DecidableEq, Repr

structure Unit where
  st : US
  /-- Holds every runtime lock key it needs. -/
  locked : Bool
  deriving DecidableEq, Repr

inductive Op where
  /-- `mark_running!`; `free` = no other owner holds a key (else `LockConflict`). -/
  | markRunning (free : Bool)
  /-- `block!`; `releasesLanding` = externally cleared or urgent pre-start. -/
  | block (releasesLanding : Bool)
  | unblock
  | markTerminal
  deriving DecidableEq, Repr

def step (u : Unit) : Op → Unit
  | .markRunning free => if free then { st := .running, locked := true } else u
  | .block rel => { st := .blocked, locked := if rel then false else u.locked }
  | .unblock => { u with st := .queued }
  | .markTerminal => { st := .terminal, locked := false }

def RunningHoldsLocks (u : Unit) : Prop := u.st = .running → u.locked = true

theorem step_preserves (u : Unit) (o : Op) (h : RunningHoldsLocks u) :
    RunningHoldsLocks (step u o) := by
  cases o with
  | markRunning free =>
    cases free
    · exact h
    · intro _; rfl
  | block rel => intro hs; simp [step] at hs
  | unblock => intro hs; simp [step] at hs
  | markTerminal => intro hs; simp [step] at hs

theorem run_preserves (u : Unit) (ops : List Op) (h : RunningHoldsLocks u) :
    RunningHoldsLocks (ops.foldl step u) := by
  induction ops generalizing u with
  | nil => exact h
  | cons o os ih => exact ih (step u o) (step_preserves u o h)

/-- Re-entry without locks is reachable: a finished unit blocked by
    `AutoRetryBackoff` is active and holds nothing... -/
theorem lockless_reentry :
    step { st := .terminal, locked := false } (.block false) = { st := .blocked, locked := false } := rfl

/-- ...but it cannot reach `running` without acquiring every key. -/
theorem reentry_runs_only_locked (ops : List Op) :
    RunningHoldsLocks (ops.foldl step { st := .terminal, locked := false }) :=
  run_preserves _ ops (by intro h; cases h)

end UnitReentry
end SyrusModel
