/-!
# The image a backend update replaced is kept for rollback (NY24, decided B)

After a backend update passes its health gate, the desktop removed every
same-channel backend image except the new pin, including the one running a
minute earlier, so rolling back meant re-pulling a multi-GB image. Now the
image the update replaced is kept deadline the next successful update replaces the
retention record, or for seven days.

The model tracks, over a sequence of events, which previous images are kept:
an update keeps exactly the image it replaced and drops the record before it;
a launch after the deadline drops the record. It proves at most one previous
image is ever kept (`at_most_one_kept`), the replaced image survives the
update's own cleanup (`update_keeps_replaced`), and nothing is kept past the
deadline after a launch (`expired_retired_at_launch`).
-/

namespace SyrusModel
namespace RollbackImage

/-- The retention record: the kept image and the day its retention ends (its deadline). -/
abbrev Retention := Option (Nat × Nat)

inductive Event where
  | update (previous next : Nat) (today : Nat)
  | launch (today : Nat)
  deriving DecidableEq, Repr

def keepDays : Nat := 7

/-- `retentionAfterUpdate`, then `retireExpiredRetainedImage` at launch. -/
def step (r : Retention) : Event → Retention
  | .update previous next today => if previous == next then none else some (previous, today + keepDays)
  | .launch today =>
    match r with
    | some (image, deadline) => if today < deadline then some (image, deadline) else none
    | none => none

def run (events : List Event) : Retention := events.foldl step none

/-- The images cleanup keeps besides the pin: the retained one, if any. -/
def keptPrevious (r : Retention) : List Nat :=
  match r with
  | some (image, _) => [image]
  | none => []

theorem at_most_one_kept (events : List Event) : (keptPrevious (run events)).length ≤ 1 := by
  unfold keptPrevious
  split <;> simp

theorem update_keeps_replaced (r : Retention) (previous next today : Nat) (h : previous ≠ next) :
    keptPrevious (step r (.update previous next today)) = [previous] := by
  simp [step, keptPrevious, h]

/-- A second update retires the image the first one kept. -/
theorem second_update_retires_first :
    keptPrevious (run [.update 1 2 0, .update 2 3 1]) = [2] := by decide

theorem expired_retired_at_launch (image deadline today : Nat) (h : deadline ≤ today) :
    keptPrevious (step (some (image, deadline)) (.launch today)) = [] := by
  simp [step, keptPrevious, Nat.not_lt.mpr h]

end RollbackImage
end SyrusModel
