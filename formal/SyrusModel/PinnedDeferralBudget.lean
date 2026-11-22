/-!
# DOC-44 runs: the pinned host-admission deferral loop terminates

`queued-run-placement-livelock`: a Run whose Workflow is pinned to one host
(worker storage affinity) keeps getting deferred by host admission. RunJob
bounds the loop with `PINNED_HOST_ADMISSION_DEFERRAL_BUDGET`: once a Run has
been deferred that many times, the Workflow's storage affinity is dropped and
the Run is rerouted elsewhere.

The count was kept in one per-Workflow artifact, keyed by run_id, and restarted
at 1 whenever a different Run recorded a deferral. Sibling Runs of one pinned
Workflow, such as parallel grader shards deferring each other on the same host,
reset each other's count on every round, so the budget never ran out (F91).
After the fix each Run's count is kept separately.

Model: a budget of 4, and a sequence of deferrals, each by one of up to three
sibling Runs.

- `each_run_exhausts`: over every sequence of up to 12 deferrals, as soon as
  some Run has been deferred `budget` times in total, affinity is dropped.
  That is a termination measure: no interleaving defers forever.
- `before_never_exhausts`: two siblings alternating for 3·budget deferrals never
  reach the budget under the old shared counter.
-/

namespace SyrusModel
namespace PinnedDeferralBudget

def budget : Nat := 4

/-- After: per-Run counters. Returns whether affinity was dropped. -/
def runAfter : List Nat → List (Nat × Nat) → Bool
  | [], _ => false
  | r :: rest, counts =>
    let c := ((counts.find? (·.1 == r)).map (·.2)).getD 0 + 1
    if c ≥ budget then true
    else runAfter rest ((r, c) :: counts.filter (·.1 != r))

/-- Before: one counter, reset when the deferring Run changes. -/
def runBefore : List Nat → Option Nat → Nat → Bool
  | [], _, _ => false
  | r :: rest, last, n =>
    let c := if last == some r then n + 1 else 1
    if c ≥ budget then true else runBefore rest (some r) c

def runs : List Nat := [0, 1, 2]

def sequences : Nat → List (List Nat)
  | 0 => [[]]
  | k + 1 => [] :: (sequences k).flatMap (fun rest => runs.map (· :: rest))

/-- Some Run has been deferred `budget` times in this sequence. -/
def someRunReachesBudget (seq : List Nat) : Bool :=
  runs.any (fun r => seq.count r ≥ budget)

def check : Bool := (sequences 12).all (fun seq => !someRunReachesBudget seq || runAfter seq [])

theorem each_run_exhausts : check = true := by native_decide

def alternating : Nat → List Nat
  | 0 => []
  | n + 1 => (n % 2) :: alternating n

theorem before_never_exhausts : runBefore (alternating (3 * budget)) none 0 = false := by native_decide

end PinnedDeferralBudget
end SyrusModel
