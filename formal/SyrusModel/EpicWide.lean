/-!
# Epic-wide Workflows and member work

Merge trains and stack rebases are Epic-wide: they act on several member Jobs'
branches. `EpicWorkflowLock.blocking_workflow_for` lets a Workflow start only
when no *other Epic-wide* Workflow is active, so an Epic-wide Workflow can start
while a member's own Workflow is running. `classify_epic_workflow_conflicts`
then keeps the oldest Epic-wide Workflow and cancels every other active
Workflow in the Epic — the running member work.

The property the reconciler encodes: while an Epic-wide Workflow is active, no
other Workflow in the Epic is active. Two ways to make it hold by construction
(decision NY2): an Epic-wide Workflow *waits* until member work is idle, or it
*preempts* member work and the victims are relaunched afterwards.
-/

namespace SyrusModel
namespace EpicWide

structure S where
  epicWide : Nat   -- active Epic-wide Workflows
  member : Nat     -- active member Workflows
  deriving DecidableEq, Repr

def Exclusive (s : S) : Bool := s.epicWide ≤ 1 && (s.epicWide = 0 || s.member = 0)

/-- Start rules as written: members wait for Epic-wide work; Epic-wide work
    waits only for other Epic-wide work. -/
def startMemberNow (s : S) : S := if s.epicWide = 0 then { s with member := s.member + 1 } else s
def startEpicWideNow (s : S) : S := if s.epicWide = 0 then { s with epicWide := 1 } else s

/-- Option A (wait): Epic-wide work also waits for member work to go idle. -/
def startEpicWideWait (s : S) : S := if s.epicWide = 0 && s.member = 0 then { s with epicWide := 1 } else s

theorem today_breaks : Exclusive (startEpicWideNow (startMemberNow ⟨0, 0⟩)) = false := by decide

def finishMember (s : S) : S := if s.member > 0 then { s with member := s.member - 1 } else s
def finishEpicWide (s : S) : S := if s.epicWide > 0 then { s with epicWide := s.epicWide - 1 } else s

inductive Op where | member | epicWide | finishMember | finishEpicWide deriving DecidableEq, Repr

def apply (s : S) : Op → S
  | .member => startMemberNow s
  | .epicWide => startEpicWideWait s
  | .finishMember => finishMember s
  | .finishEpicWide => finishEpicWide s

def seqs : Nat → List (List Op)
  | 0 => [[]]
  | n + 1 => [[]] ++ (seqs n).flatMap fun l => [Op.member, .epicWide, .finishMember, .finishEpicWide].map (· :: l)

def runOps : List Op → S → S
  | [], s => s
  | o :: os, s => runOps os (apply s o)

/-- With option A every interleaving of up to 6 starts/finishes stays exclusive. -/
theorem wait_rule_exclusive : (seqs 6).all (fun os => Exclusive (runOps os ⟨0, 0⟩)) = true := by native_decide

/-! ## Decided (NY2): both directions wait, nothing is preempted

Refined with queued vs running. Members wait while Epic-wide work is queued or
running (`EpicWorkflowLock.blocking_workflow_for`); Epic-wide work waits while
any member is *running* (`running_member_workflow`). Waiting also for queued
members would deadlock: queued members wait for the queued Epic-wide Workflow,
which waits for them. -/

structure Q where
  mQueued : Nat
  mRunning : Nat
  ewQueued : Bool
  ewRunning : Bool
  deriving DecidableEq, Repr

inductive QOp where
  | enqueueMember | enqueueEW | startMember | startEW | finishMember | finishEW
  deriving DecidableEq, Repr

def startMemberOk (s : Q) : Bool := s.mQueued > 0 && !s.ewQueued && !s.ewRunning
/-- The decided rule: only running members hold Epic-wide work back. -/
def startEWOk (s : Q) : Bool := s.ewQueued && s.mRunning = 0
/-- A naive reading: any active (queued or running) member holds it back. -/
def startEWOkNaive (s : Q) : Bool := s.ewQueued && s.mRunning = 0 && s.mQueued = 0

def qstep (ewOk : Q → Bool) (s : Q) : QOp → Q
  | .enqueueMember => { s with mQueued := s.mQueued + 1 }
  | .enqueueEW => if s.ewQueued || s.ewRunning then s else { s with ewQueued := true }
  | .startMember => if startMemberOk s then { s with mQueued := s.mQueued - 1, mRunning := s.mRunning + 1 } else s
  | .startEW => if ewOk s then { s with ewQueued := false, ewRunning := true } else s
  | .finishMember => if s.mRunning > 0 then { s with mRunning := s.mRunning - 1 } else s
  | .finishEW => if s.ewRunning then { s with ewRunning := false } else s

def qrun (ewOk : Q → Bool) : List QOp → Q → Q
  | [], s => s
  | o :: os, s => qrun ewOk os (qstep ewOk s o)

def qseqs : Nat → List (List QOp)
  | 0 => [[]]
  | n + 1 => [[]] ++ (qseqs n).flatMap fun l =>
      [QOp.enqueueMember, .enqueueEW, .startMember, .startEW, .finishMember, .finishEW].map (· :: l)

def QExclusive (s : Q) : Bool := !(s.ewRunning && s.mRunning > 0)

/-- Something is waiting and nothing is running, yet nothing may start. -/
def Deadlocked (ewOk : Q → Bool) (s : Q) : Bool :=
  (s.mQueued > 0 || s.ewQueued) && s.mRunning = 0 && !s.ewRunning && !startMemberOk s && !ewOk s

def q0 : Q := ⟨0, 0, false, false⟩

/-- The naive rule deadlocks: a member queued behind a queued Epic-wide Workflow. -/
theorem naive_deadlocks : Deadlocked startEWOkNaive (qrun startEWOkNaive [.enqueueEW, .enqueueMember] q0) = true := by
  decide

/-- The decided rule keeps the Epic exclusive under every interleaving of up to
    6 operations from idle... -/
theorem decided_exclusive :
    (qseqs 6).all (fun os => QExclusive (qrun startEWOk os q0)) = true := by native_decide

/-- ...and never reaches a deadlock... -/
theorem decided_deadlock_free :
    (qseqs 6).all (fun os => !Deadlocked startEWOk (qrun startEWOk os q0)) = true := by native_decide

/-- ...and a queued Epic-wide Workflow cannot be starved: while it waits, no
    member may start, so once the running members finish it can start. -/
theorem queued_epic_wide_blocks_new_members (s : Q) (h : s.ewQueued = true) :
    startMemberOk s = false := by
  simp [startMemberOk, h]

theorem queued_epic_wide_starts_when_members_idle (s : Q) (h : s.ewQueued = true)
    (hm : s.mRunning = 0) : startEWOk s = true := by
  simp [startEWOk, h, hm]

end EpicWide
end SyrusModel
