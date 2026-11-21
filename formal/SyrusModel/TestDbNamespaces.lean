/-!
# Concurrent graders never share a test database

Derived from a recent main commit ("Keep parallel RSpec preflight graders on
their own test databases"). Main-repair preflight graders run concurrently in
one checkout; each gets a namespace (`PreflightGraderPolicy`, `pf<n>`) through
`SYRUS_TEST_DB_NAMESPACE` and `TEST_ENV_NUMBER`. parallel_tests overwrites
`TEST_ENV_NUMBER` per worker (`""`, `"2"`, `"3"`, ...), so
`config/database.yml` builds the file suffix as
`[SYRUS_TEST_DB_NAMESPACE, TEST_ENV_NUMBER].reject(&:empty?).uniq.join("-")`.

Invariants, checked exhaustively for 30 graders × 30 workers (the database
name is a pure function of these two strings, so the bound covers every fleet
of that size):

* distinct (grader, worker) pairs get distinct database files
  (`suffix_injective`), including a single-process grader, whose
  `TEST_ENV_NUMBER` is the namespace itself;
* the per-namespace cleanup glob (`test<ns>.sqlite3*`, `test<ns>-*.sqlite3*`)
  never matches another grader's files (`cleanup_scoped`), e.g. `pf1` does not
  delete `pf10`'s.

No bug found.
-/

namespace SyrusModel
namespace TestDbNamespaces

def nsName (n : Nat) : String := "pf" ++ toString n

/-- A worker's `TEST_ENV_NUMBER`: `none` is a single-process grader (the
    namespace itself); `some 0` is parallel_tests' first worker (`""`);
    `some k` (k ≥ 2) the others. -/
def testEnvNumber (n : Nat) : Option Nat → String
  | none => nsName n
  | some 0 => ""
  | some k => toString k

/-- `[ns, ten].reject(&:empty?).uniq.join("-")` -/
def suffix (n : Nat) (w : Option Nat) : String :=
  let parts := [nsName n, testEnvNumber n w].filter (· ≠ "")
  "-".intercalate parts.eraseDups

def workers (bound : Nat) : List (Option Nat) := none :: some 0 :: (List.range bound).filterMap (fun k => if k ≥ 2 then some (some k) else none)

def pairs (bound : Nat) : List (Nat × Option Nat) :=
  (List.range bound).flatMap (fun n => (workers bound).map (n, ·))

/-- A single-process grader and the first parallel worker of the same grader
    are the same process role (the grader's own database); every other pair
    is distinct. -/
def sameRole : Nat × Option Nat → Nat × Option Nat → Bool
  | (n, w), (m, v) => n == m && (w == v || (w.getD 0 == 0 && v.getD 0 == 0))

def injective (bound : Nat) : Bool :=
  (pairs bound).all (fun a => (pairs bound).all (fun b => suffix a.1 a.2 != suffix b.1 b.2 || sameRole a b))

theorem suffix_injective : injective 30 = true := by native_decide

/-- The cleanup globs for namespace `n`, applied to a database file suffix. -/
def cleanupMatches (n : Nat) (s : String) : Bool :=
  s == nsName n || s.startsWith (nsName n ++ "-")

def cleanupScoped (bound : Nat) : Bool :=
  (pairs bound).all (fun a => (List.range bound).all (fun n => !cleanupMatches n (suffix a.1 a.2) || n == a.1))

theorem cleanup_scoped : cleanupScoped 30 = true := by native_decide

end TestDbNamespaces
end SyrusModel
