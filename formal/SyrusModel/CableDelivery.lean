/-!
# DOC-44 desktop: subscription rejection delivers no messages

"Subscription rejection delivers no messages", within the desktop ActionCable
client (`AppUserCableClient`, `desktop/electron/appUserCable.ts`).

Before the fix, every frame with a `message` key reached `onMessage`. That
included:

- ActionCable pings (`{type: "ping", message: <timestamp>}`, every few
  seconds);
- broadcasts before the subscription was confirmed;
- broadcasts after a rejection;
- broadcasts for another identifier.

After the fix, a socket delivers a frame only while its own subscription is
confirmed and not rejected, and only an untyped broadcast carrying this
channel's identifier (F81).

Over every sequence of up to six frames on one socket:

- each delivered frame is an own-channel broadcast that follows a
  `confirm_subscription` with no `reject_subscription` before it
  (`delivers_only_confirmed_own_broadcasts`). The old behaviour violates this
  (`before_violates`);
- a broadcast after a confirmation is delivered (`confirmed_broadcast_delivered`).

Stale sockets are covered separately by the client's generation check: a
callback from a socket of an older generation returns before anything else.
-/

namespace SyrusModel
namespace CableDelivery

inductive Frame where
  | welcome
  | ping
  | confirm
  | reject
  | broadcast (ownChannel : Bool)
deriving DecidableEq, Repr

/-- After: per-socket `subscribed`, typed frames never delivered. -/
def deliverAfter : Bool → List Frame → List Frame
  | _, [] => []
  | subscribed, f :: rest =>
    match f with
    | .confirm => deliverAfter true rest
    | .reject => deliverAfter false rest
    | .broadcast true => (if subscribed then [f] else []) ++ deliverAfter subscribed rest
    | _ => deliverAfter subscribed rest

/-- Before: anything with a `message` key. -/
def deliverBefore : List Frame → List Frame
  | [] => []
  | f :: rest =>
    match f with
    | .ping | .broadcast _ => f :: deliverBefore rest
    | _ => deliverBefore rest

def allFrames : List Frame := [.welcome, .ping, .confirm, .reject, .broadcast true, .broadcast false]

def sequences : Nat → List (List Frame)
  | 0 => [[]]
  | k + 1 => [] :: (sequences k).flatMap (fun rest => allFrames.map (· :: rest))

/-- Every delivered frame is an own-channel broadcast at a point where the latest
subscription answer was a confirmation. -/
def legal (frames : List Frame) (delivered : List Frame) : Bool :=
  let positions := (List.range frames.length).filter (fun i =>
    frames[i]? == some (.broadcast true) &&
      match ((frames.take i).reverse.find? (fun f => f == .confirm || f == .reject)) with
      | some .confirm => true
      | _ => false)
  delivered == positions.map (fun _ => Frame.broadcast true)

def check : Bool := (sequences 6).all (fun fs => legal fs (deliverAfter false fs))

theorem delivers_only_confirmed_own_broadcasts : check = true := by native_decide

theorem before_violates :
    legal [.welcome, .ping, .reject, .broadcast true] (deliverBefore [.welcome, .ping, .reject, .broadcast true]) = false := by
  native_decide

theorem confirmed_broadcast_delivered :
    deliverAfter false [.welcome, .confirm, .ping, .broadcast true] = [.broadcast true] := by native_decide

end CableDelivery
end SyrusModel
