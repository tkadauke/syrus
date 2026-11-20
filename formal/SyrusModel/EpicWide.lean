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

end EpicWide
end SyrusModel
