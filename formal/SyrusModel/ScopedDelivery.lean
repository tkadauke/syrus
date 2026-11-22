/-!
# DOC-44 frontend: a revoked subscriber stops receiving a Job's events

DOC-44 frontend invariant: "Job- and Chat-scoped events cannot affect another
resource or unauthorized user." NY20 (decided): prevent a user who loses
access to a Job from receiving its live updates.

`JobChannel` streams one shared `job_resource:<id>` stream per Job and checked
`Job.visible_to` only on subscribe. A user whose access was revoked while the
tab was open kept receiving every Workflow, Step and Run patch until the
connection dropped (`revoked_kept_receiving`).

After the fix, every delivery rechecks visibility, trusting a positive answer
for at most `interval` ticks. Once the check fails, the stream stops for good.
Over every revocation tick and every pattern of message ticks on a ten-tick
timeline, with intervals 1 to 3, no message is delivered more than `interval`
ticks after revocation, and every message before revocation is delivered
(`bounded_after_revocation`).
-/

namespace SyrusModel
namespace ScopedDelivery

structure State where
  checkedAt : Nat
  stopped : Bool
  delivered : List Nat
deriving Repr

/-- After: deliver at tick `t` if the cached answer is fresh, otherwise
    recheck visibility (`t < revokedAt`). -/
def step (interval revokedAt : Nat) (s : State) (t : Nat) : State :=
  if s.stopped then s
  else if t < s.checkedAt + interval then { s with delivered := s.delivered ++ [t] }
  else if t < revokedAt then { s with checkedAt := t, delivered := s.delivered ++ [t] }
  else { s with stopped := true }

def run (interval revokedAt : Nat) (messages : List Nat) : List Nat :=
  (messages.foldl (step interval revokedAt) ⟨0, false, []⟩).delivered

/-- Before: checked on subscribe only. -/
def runBefore (messages : List Nat) : List Nat := messages

def subsets : List Nat → List (List Nat)
  | [] => [[]]
  | x :: xs => (subsets xs).flatMap (fun s => [x :: s, s])

def check : Bool :=
  [1, 2, 3].all (fun interval => (List.range 10).all (fun revokedAt =>
    (subsets (List.range 10)).all (fun messages =>
      let got := run interval revokedAt messages
      got.all (fun t => t < revokedAt + interval) &&
        messages.all (fun t => t ≥ revokedAt || got.contains t))))

theorem bounded_after_revocation : check = true := by native_decide

/-- Before: revoked at tick 2, still receiving at tick 9. -/
theorem revoked_kept_receiving :
    (runBefore [1, 9]).contains 9 = true ∧ (run 3 2 [1, 9]).contains 9 = false := by
  decide

end ScopedDelivery
end SyrusModel
