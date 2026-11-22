/-!
# DOC-44 plugin host: a worker without a plugin never fails that plugin's step early

NY17 (decided): "We need to prevent that." A worker that lacks a plugin can
claim a Run of that plugin's step kind, because a Run is routed to a queue
every worker of that OS consumes. `Steps.handler_for` then raised and the Step
failed terminally (`failed_on_first_wrong_worker`).

After the fix, a worker that does not provide the step's kind hands the Run
back to the queue, at most `limit` times, before letting it fail as unknown. A
capable worker that claims it in the meantime runs it. Over every claim
sequence of up to six claims by capable (`true`) or incapable (`false`)
workers, with a limit of 3:

- the Step fails only after `limit` hand-backs (`fails_only_after_budget`);
- if a capable worker claims it before the budget is spent, it runs
  (`capable_claim_runs`).

Routing by plugin (per-plugin queues) would avoid the hand-backs entirely;
that is a larger change, noted with NY17.
-/

namespace SyrusModel
namespace UnknownKindHandback

inductive Outcome where
  | ran
  | failed
  | pending
deriving DecidableEq, Repr

def limit : Nat := 3

/-- After: each incapable claim hands back until the budget is spent. -/
def run : Nat → List Bool → Outcome
  | _, [] => .pending
  | n, capable :: rest =>
    if capable then .ran
    else if n < limit then run (n + 1) rest
    else .failed

/-- Before: the first claim decided. -/
def runBefore : List Bool → Outcome
  | [] => .pending
  | capable :: _ => if capable then .ran else .failed

def claims : Nat → List (List Bool)
  | 0 => [[]]
  | k + 1 => [] :: (claims k).flatMap (fun c => [true :: c, false :: c])

def handbacksBeforeCapable (cs : List Bool) : Nat := (cs.takeWhile (· == false)).length

def check : Bool :=
  (claims 6).all (fun cs =>
    let outcome := run 0 cs
    (outcome != .failed || handbacksBeforeCapable cs > limit) &&
      (!(cs.take (limit + 1)).contains true || outcome == .ran))

theorem fails_only_after_budget_and_capable_claim_runs : check = true := by native_decide

theorem failed_on_first_wrong_worker :
    runBefore [false, true] = .failed ∧ run 0 [false, true] = .ran := by
  decide

end UnknownKindHandback
end SyrusModel
