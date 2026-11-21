/-!
# DOC-44 frontend: every delivered event is applied exactly once

DOC-44 frontend invariants: "Duplicate events are observationally idempotent,"
and the network "may drop, duplicate, delay, and reorder events."

`AppEvents.broadcast` stamps each user-channel event with a per-user
`sequence`, allocated in the database and then published by whichever
process broadcasts. Allocation and publication are not atomic across
processes, so the client can receive 11 before 10. `trackAppEventSequence`
treated every sequence not above the highest seen as a duplicate, so a late
10 was dropped outright, together with its entity patch and invalidation
(`late_event_dropped`). The gap detected at 11 refreshed only 11's resource,
so 10's resource stayed stale.

After the fix, the client remembers the sequences it has seen within a window
below the highest. Only a seen sequence is a duplicate, and an unseen lower
one is applied as a late delivery. Then, for every delivery order of up to
four distinct events, with any one of them delivered twice, every event is
applied exactly once (`applied_exactly_once`). Older fields still cannot win:
the entity store's revision guard is independent of the sequence. Recovering
an event that never arrives, whose resource is unknown, is NY19.
-/

namespace SyrusModel
namespace EventSequence

structure Client where
  highest : Option Nat
  seen : List Nat
  applied : List Nat
deriving Repr

def empty : Client := ⟨none, [], []⟩

/-- Before: anything not above the highest is a duplicate. -/
def receiveBefore (c : Client) (s : Nat) : Client :=
  match c.highest with
  | none => ⟨some s, [s], c.applied ++ [s]⟩
  | some h => if s > h then ⟨some s, c.seen ++ [s], c.applied ++ [s]⟩ else c

/-- After: only a seen sequence is a duplicate (window larger than any trace). -/
def receive (c : Client) (s : Nat) : Client :=
  if c.seen.contains s then c
  else ⟨some (max s (c.highest.getD s)), c.seen ++ [s], c.applied ++ [s]⟩

def runWith (f : Client → Nat → Client) (deliveries : List Nat) : Client := deliveries.foldl f empty

def permutations : List Nat → List (List Nat)
  | [] => [[]]
  | x :: xs => (permutations xs).flatMap (fun p =>
      (List.range (p.length + 1)).map (fun i => p.take i ++ [x] ++ p.drop i))

def exactlyOnce (applied events : List Nat) : Bool :=
  events.all (fun e => applied.count e == 1) && applied.length == events.length

def check : Bool :=
  (List.range 5).all (fun n =>
    let events := (List.range n).map (· + 1)
    (permutations events).all (fun order =>
      exactlyOnce (runWith receive order).applied events &&
      (List.range order.length).all (fun i =>
        let dup := order.take (i + 1) ++ [order.getD i 0] ++ order.drop (i + 1)
        exactlyOnce (runWith receive dup).applied events)))

theorem applied_exactly_once : check = true := by native_decide

/-- Before: 11 arriving before 10 drops 10. -/
theorem late_event_dropped :
    (runWith receiveBefore [9, 11, 10]).applied = [9, 11] ∧
      (runWith receive [9, 11, 10]).applied = [9, 11, 10] := by
  decide

end EventSequence
end SyrusModel
