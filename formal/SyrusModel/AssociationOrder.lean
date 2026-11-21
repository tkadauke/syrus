/-!
# An appended `order` cannot override an association's default order

Derived from a recent main commit ("Return a Job's newest workflows from the
admin API, not its oldest") and found to be a whole class.

`Job#workflows`, `Job#runs`, `Step#runs`, `Workflow#steps`, `Run#job_logs`,
`MergeTrain#members` and others carry a default `order` scope. ActiveRecord's
`.order(x)` *appends* `x` to it, so
`job.workflows.order(created_at: :desc).first` runs
`ORDER BY created_at ASC, id ASC, created_at DESC, id DESC` and returns the
*oldest* row. `reorder(x)` replaces the default.

Proved over every list of up to six distinct timestamps (`native_decide`):
with the default ascending key first, appending a descending key on the same
column changes nothing, so "newest" lookups return the minimum
(`appended_desc_is_ascending`); `reorder` returns the maximum
(`reorder_desc_first_is_newest`).

Forty-one such lookups across `app` and `plugins` returned the oldest record:
the run-failure classifier read a run's first log lines as its "recent" ones,
landing failure handling read the oldest failed run's error, the reconciler's
retry picked the lowest failed step, checkpoint resume and several retries
picked the oldest candidate. All now use `reorder`;
`spec/architecture/default_ordered_association_spec.rb` fails on any
descending `order` chained onto a default-ordered association.
-/

namespace SyrusModel
namespace AssociationOrder

inductive Dir where | asc | desc deriving DecidableEq, Repr

/-- `ORDER BY` with every key on the same column (the row's timestamp). -/
def before (keys : List Dir) (a b : Nat) : Bool :=
  match keys with
  | [] => false
  | .asc :: rest => a < b || (a == b && before rest a b)
  | .desc :: rest => a > b || (a == b && before rest a b)

def insertBy (keys : List Dir) (x : Nat) : List Nat → List Nat
  | [] => [x]
  | y :: ys => if before keys x y then x :: y :: ys else y :: insertBy keys x ys

def sortBy (keys : List Dir) (xs : List Nat) : List Nat := xs.foldr (insertBy keys) []

/-- Default scope `order(:created_at)` followed by `.order(created_at: :desc)`. -/
def appended : List Dir := [.asc, .desc]
/-- `.reorder(created_at: :desc)` -/
def reordered : List Dir := [.desc]

def distinctLists : Nat → List (List Nat)
  | 0 => [[]]
  | n + 1 => (distinctLists n) ++ ((distinctLists n).flatMap (fun xs =>
      (List.range 6).filterMap (fun v => if xs.contains v then none else some (v :: xs))))

theorem appended_desc_is_ascending :
    (distinctLists 6).all (fun xs => (sortBy appended xs).head? == (xs.min?)) = true := by native_decide

theorem reorder_desc_first_is_newest :
    (distinctLists 6).all (fun xs => (sortBy reordered xs).head? == (xs.max?)) = true := by native_decide

/-- The concrete case: three workflows; "the newest" was the oldest. -/
example : (sortBy appended [20, 10, 30]).head? = some 10 := by decide
example : (sortBy reordered [20, 10, 30]).head? = some 30 := by decide

end AssociationOrder
end SyrusModel
