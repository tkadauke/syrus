/-!
# Lock acquisition never succeeds without a lock row

`WorkUnit#ensure_active_locks!` and `WorkUnits::Launcher#create_lock!` insert a
`WorkUnitLock` and rely on the unique index on `active_lock_key`. On a
uniqueness violation they look up the owner; if the lookup finds none they
returned as if acquisition had succeeded. The lookup finds none exactly when the
owner released the key between our failed insert and the lookup — the key is
free, and we hold nothing. The unit then runs without the lock it needs, and a
third unit can take the key: `LockSafety.HoldsOwnLocks` breaks.

Fix: after a violation with no owner, retry the insert; if that also fails,
raise `LockConflict`.

The environment interleaves: the key is held by another unit, it may be
released at any point, and a third unit may take a free key.
-/

namespace SyrusModel
namespace LockAcquire

inductive Holder where | none | us | other deriving DecidableEq, Repr

/-- Result of an acquisition attempt. -/
inductive Res where | acquired | conflict | silentNoLock deriving DecidableEq, Repr

/-- One insert attempt against the current holder. -/
def insert (h : Holder) : Option Holder := if h = .none then some .us else Option.none

/-- `releaseBetween`: the other owner releases right after our failed insert. -/
def acquireOld (h : Holder) (releaseBetween : Bool) : Holder × Res :=
  match insert h with
  | some h' => (h', .acquired)
  | none =>
    let h' := if releaseBetween then Holder.none else h
    if h' = .other then (h', .conflict) else (h', .silentNoLock)

def acquireNew (h : Holder) (releaseBetween : Bool) : Holder × Res :=
  match insert h with
  | some h' => (h', .acquired)
  | none =>
    let h' := if releaseBetween then Holder.none else h
    if h' = .other then (h', .conflict)
    else match insert h' with
      | some h'' => (h'', .acquired)
      | none => (h', .conflict)

/-- "Acquired" means we hold the key; anything else is reported as a conflict. -/
def sound (r : Holder × Res) : Bool :=
  match r.2 with
  | .acquired => r.1 = .us
  | .conflict => true
  | .silentNoLock => false

theorem old_silent_no_lock : acquireOld .other true = (.none, .silentNoLock) := by decide

theorem new_sound :
    [Holder.none, .us, .other].all (fun h => [true, false].all fun b => sound (acquireNew h b)) = true := by
  decide

end LockAcquire
end SyrusModel
