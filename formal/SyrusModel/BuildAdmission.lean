/-!
# Runtime image build admission respects the global cap (F134)

`RuntimeImages::Builds::Orchestrator#claim` admits a queued build request if
fewer than `max_concurrent_builds` are in flight (and fewer than the namespace
cap in its namespace). It is check-then-act: read the in-flight count, then
create the attempt that adds one. The recurring `RuntimeImageBuildDispatchJob`
only skips while another run is *pending*, so two dispatch runs can be claiming
at the same time.

Each claimer runs `acquire`, `check`, `admit`, `release`. A claimer may only
hold a lock no one else holds. Before the fix each claim held only its own
namespace's lock; after it, every claim first takes one instance-wide lock
(the AppSetting row).

This file enumerates every interleaving of two claimers in different
namespaces with a global cap of one:

* `per_namespace_lock_oversubscribes`: with namespace locks only, both check
  the count at zero and both admit, so two builds run under a cap of one;
* `global_lock_respects_cap`: with the instance-wide lock, no interleaving
  ever admits more than the cap.
-/

namespace SyrusModel
namespace BuildAdmission

/-- How far a claimer has got. -/
inductive Pc
  | start | locked | checked (ok : Bool) | done
  deriving DecidableEq, Repr

structure State where
  pcs : List Pc       -- one per claimer
  inFlight : Nat
  holder : List (Option Nat)  -- per lock key, who holds it
  deriving DecidableEq, Repr

/-- The lock key claimer `i` takes: its namespace's, or the one global key. -/
def keyOf (global : Bool) (i : Nat) : Nat := if global then 0 else i

def cap : Nat := 1

def setAt {α} : List α → Nat → α → List α
  | [], _, _ => []
  | _ :: t, 0, v => v :: t
  | h :: t, n + 1, v => h :: setAt t n v

/-- Claimer `i` takes one step, if it can. -/
def step (global : Bool) (s : State) (i : Nat) : Option State :=
  let k := keyOf global i
  match s.pcs.getD i .done with
  | .start =>
    if s.holder.getD k none == none then
      some { s with pcs := setAt s.pcs i .locked, holder := setAt s.holder k (some i) }
    else none
  | .locked => some { s with pcs := setAt s.pcs i (.checked (decide (s.inFlight < cap))) }
  | .checked ok =>
    some { s with pcs := setAt s.pcs i .done, inFlight := if ok then s.inFlight + 1 else s.inFlight,
                  holder := setAt s.holder k none }
  | .done => none

def init : State := { pcs := [.start, .start], inFlight := 0, holder := [none, none] }

/-- Every state reachable in at most `n` steps. -/
def reach (global : Bool) : Nat → List State
  | 0 => [init]
  | n + 1 =>
    let prev := reach global n
    prev ++ prev.flatMap (fun s => [0, 1].filterMap (step global s))

theorem per_namespace_lock_oversubscribes :
    (reach false 6).any (fun s => s.inFlight > cap) = true := by native_decide

theorem global_lock_respects_cap :
    (reach true 6).all (fun s => s.inFlight ≤ cap) = true := by native_decide

/-- Six steps finish both claimers (three steps each), so the bound covers
every complete run. -/
theorem six_steps_finish :
    (reach true 6).any (fun s => s.pcs = [.done, .done]) = true := by native_decide

end BuildAdmission
end SyrusModel
