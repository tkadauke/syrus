/-!
# A worker cache lease protects every live holder (F132)

`RuntimeImages::WorkerCache` leases a cache entry for each acquisition and
evicts only entries that are not leased. The lease is one row: a holder count
and an expiry. Acquiring an expired lease starts it over at one holder, so a
crashed holder cannot pin an entry forever. The cache's documented guarantee
is that an acquired image is never removed.

A holder whose lease expired is still running, though: a container run can
outlast the lease. When it finished, `release` decremented the count anyway.
That count now belonged to the holder that started the lease over, so it
dropped to zero and eviction could remove that holder's image
(`stale_release_unprotects`).

The fix numbers each started-over lease with an epoch. An acquisition records
the epoch it joined, and a release only counts down a lease of the same epoch.
Then the count always equals the number of holders in the current epoch
(`count_eq_current`). So while the lease is live, an entry with a current
holder is protected (`current_holder_protected`), whatever expired holders do.

Abstract state: the count, the live current-epoch holders, the live holders of
older epochs, and whether the lease has expired. Holders are interchangeable
within an epoch, so they are counted rather than named.
-/

namespace SyrusModel
namespace CacheLease

structure State where
  count : Nat
  current : Nat
  stale : Nat
  live : Bool
deriving DecidableEq, Repr

inductive Op
  | acquire
  | expire
  | releaseCurrent
  | releaseStale

/-- Which `release` the cache runs. -/
inductive Release
  | unconditional -- before: always counts down
  | epochScoped -- after: only a release of the current epoch counts down

def step (rel : Release) (s : State) : Op → State
  | .acquire =>
    if s.live then { s with count := s.count + 1, current := s.current + 1 }
    else { count := 1, current := 1, stale := s.stale + s.current, live := true }
  | .expire => { s with live := false }
  | .releaseCurrent =>
    if s.current = 0 then s else { s with count := s.count - 1, current := s.current - 1 }
  | .releaseStale =>
    if s.stale = 0 then s
    else match rel with
      | .unconditional => { s with count := s.count - 1, stale := s.stale - 1 }
      | .epochScoped => { s with stale := s.stale - 1 }

def run (rel : Release) (s : State) (ops : List Op) : State := ops.foldl (step rel) s

def init : State := { count := 0, current := 0, stale := 0, live := false }

/-- Eviction's claim matches only an entry whose lease is expired or has no
holders. -/
def protected_ (s : State) : Bool := s.live && s.count > 0

/-- Before: a holder outlives its lease, another acquisition starts it over,
the first one releases. The second holder is live but unprotected. -/
theorem stale_release_unprotects :
    let s := run .unconditional init [ .acquire, .expire, .acquire, .releaseStale ]
    s.current = 1 ∧ s.live = true ∧ protected_ s = false := by decide

theorem count_eq_current_step (s : State) (op : Op) (h : s.count = s.current) :
    (step .epochScoped s op).count = (step .epochScoped s op).current := by
  obtain ⟨c, cur, st, l⟩ := s
  simp only at h
  subst h
  cases op <;> cases l <;> simp only [step] <;>
    first
    | rfl
    | (by_cases hz : c = 0 <;> simp [hz])
    | (by_cases hz : st = 0 <;> simp [hz])

/-- After: the count is exactly the live current-epoch holders, from any
history. -/
theorem count_eq_current (ops : List Op) :
    (run .epochScoped init ops).count = (run .epochScoped init ops).current := by
  unfold run
  suffices ∀ s : State, s.count = s.current →
      (ops.foldl (step .epochScoped) s).count = (ops.foldl (step .epochScoped) s).current from
    this init rfl
  induction ops with
  | nil => intro s h; simpa using h
  | cons op rest ih => intro s h; exact ih _ (count_eq_current_step s op h)

/-- After: while the lease is live, an entry with a current holder is never
evictable, whatever expired holders release. -/
theorem current_holder_protected (ops : List Op)
    (hlive : (run .epochScoped init ops).live = true)
    (hheld : (run .epochScoped init ops).current > 0) :
    protected_ (run .epochScoped init ops) = true := by
  have := count_eq_current ops
  simp [protected_, hlive]
  omega

/-- The same trace is harmless after the fix. -/
theorem stale_release_harmless :
    protected_ (run .epochScoped init [ .acquire, .expire, .acquire, .releaseStale ]) = true := by decide

end CacheLease
end SyrusModel
