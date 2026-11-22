/-!
# DOC-44 frontend: a lost app event is always recovered, a late one never costs a sweep

DOC-44's "global sequence-gap issue". NY19 (decided): "wait about 2 s for late
deliveries, then sweep active continuity queries for any sequence still
missing."

When the client sees sequence 10 and then 12, it refreshed only the queries of
event 12. Event 11's resource is unknown, so if 11 never arrived its resource
stayed stale until an unrelated reconnect or refetch (`lost_left_stale`). F67
made late deliveries apply, so a gap usually closes on its own.

After the fix, a gap records the missing sequences and starts one grace timer.
A late delivery removes its sequence. When the timer fires, any sequence still
missing triggers the continuity sweep a reconnect runs. Modelled over every
assignment of up to four events to "arrives at tick t" (t in 0..3) or "lost",
delivered in tick order, with a grace period of 2 ticks after the first gap:

- a sweep happens exactly when some event in the gap is still missing when
  the timer fires (`sweeps_iff_still_missing`);
- so every event lost for good is recovered by a sweep, and a gap that closes
  within the grace period costs none.
-/

namespace SyrusModel
namespace GapRecovery

/-- `none` = lost; `some t` = arrives at tick `t`. Sequence `i + 1` for index `i`. -/
abbrev Plan := List (Option Nat)

def grace : Nat := 2

/-- Arrivals as (tick, sequence), in tick order, ties by sequence. -/
def arrivals (plan : Plan) : List (Nat × Nat) :=
  let indexed := (List.range plan.length).filterMap (fun i => (plan.getD i none).map (fun t => (t, i + 1)))
  indexed.mergeSort (fun a b => a.1 < b.1 || (a.1 == b.1 && a.2 ≤ b.2))

structure Client where
  highest : Nat
  seen : List Nat
  missing : List Nat
  gapAt : Option Nat
deriving Repr

def receive (c : Client) (tick s : Nat) : Client :=
  if c.seen.contains s then c
  else if s > c.highest then
    let skipped := (List.range (s - c.highest - 1)).map (fun k => c.highest + 1 + k)
    { highest := s, seen := c.seen ++ [s], missing := c.missing ++ skipped,
      gapAt := if skipped.isEmpty then c.gapAt else c.gapAt.orElse (fun _ => some tick) }
  else { c with seen := c.seen ++ [s], missing := c.missing.filter (· != s) }

/-- The state when the grace timer fires: every arrival before `gapAt + grace`. -/
def atTimer (plan : Plan) : Option (List Nat) :=
  let deliveries := arrivals plan
  let final := deliveries.foldl (fun c (d : Nat × Nat) => receive c d.1 d.2) ⟨0, [], [], none⟩
  final.gapAt.map (fun g =>
    let before := deliveries.filter (fun (d : Nat × Nat) => d.1 < g + grace)
    (before.foldl (fun c (d : Nat × Nat) => receive c d.1 d.2) ⟨0, [], [], none⟩).missing)

def sweeps (plan : Plan) : Bool := (atTimer plan).any (fun missing => !missing.isEmpty)

/-- Some sequence below the highest delivered was skipped and had still not
    arrived when the timer fired. -/
def stillMissing (plan : Plan) : Bool :=
  let deliveries := arrivals plan
  match (deliveries.foldl (fun c (d : Nat × Nat) => receive c d.1 d.2) ⟨0, [], [], none⟩).gapAt with
  | none => false
  | some g =>
    let before := deliveries.filter (fun (d : Nat × Nat) => d.1 < g + grace)
    let highestBefore := (before.map (·.2)).foldl max 0
    (List.range highestBefore).any (fun k => !(before.map (·.2)).contains (k + 1))

def outcomes : List (Option Nat) := [none, some 0, some 1, some 2, some 3]

def plans : Nat → List Plan
  | 0 => [[]]
  | k + 1 => (plans k).flatMap (fun p => outcomes.map (fun o => p ++ [o]))

def check : Bool := (List.range 5).all (fun n => (plans n).all (fun p => sweeps p == stillMissing p))

theorem sweeps_iff_still_missing : check = true := by native_decide

/-- Before: 2 is lost; nothing ever refreshes its resource. After: the sweep
    runs. A gap that closes in time costs no sweep. -/
theorem lost_left_stale :
    sweeps [some 0, none, some 1] = true ∧ sweeps [some 0, some 2, some 1] = false := by
  native_decide

end GapRecovery
end SyrusModel
