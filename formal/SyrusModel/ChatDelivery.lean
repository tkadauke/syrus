/-!
# DOC-44 frontend: chat-scoped events reach exactly the authorized subscribers

DOC-44 frontend invariant: "Job- and Chat-scoped events cannot affect another
resource or unauthorized user," together with the converse, that every
authorized subscriber is reached.

`ChatChannel` lets a user subscribe when the chat is in
`accessible_chat_sessions`: owner, participant, or a `ChatShare` target. The
owner is always a participant (`add_owner_participant`). Each subscription
streams from its own `(chat, user)` stream. `AppEvents.broadcast_chat_resource`
published only to participants' streams, so a share viewer, who by validation
is never a participant, subscribed successfully and then received no message
(`viewer_missed`). While connected, `Chat.tsx` does not poll.

After the fix, recipients are participants together with share targets,
recomputed on every broadcast. Over every state of four users (each a
participant or not, a share target or not, subscribed or not), the subscribers
reached are exactly those authorized now (`reaches_exactly_authorized`). A
subscription opened while authorized stops receiving once its share or
membership is removed, because recipients are read on each broadcast.
`JobChannel` streams one shared `job_resource:<id>` stream and authorizes only
on subscribe: NY20.
-/

namespace SyrusModel
namespace ChatDelivery

structure UserState where
  participant : Bool
  shared : Bool
  subscribed : Bool
deriving DecidableEq, Repr

def authorized (u : UserState) : Bool := u.participant || u.shared

def recipientBefore (u : UserState) : Bool := u.participant

def recipient (u : UserState) : Bool := u.participant || u.shared

def reached (r : UserState → Bool) (u : UserState) : Bool := u.subscribed && r u

def states : List UserState :=
  [true, false].flatMap (fun p => [true, false].flatMap (fun s => [true, false].map (fun sub => ⟨p, s, sub⟩)))

def worlds : Nat → List (List UserState)
  | 0 => [[]]
  | k + 1 => (worlds k).flatMap (fun w => states.map (fun u => u :: w))

def check : Bool :=
  (worlds 4).all (fun w => w.all (fun u => reached recipient u == (u.subscribed && authorized u)))

theorem reaches_exactly_authorized : check = true := by native_decide

/-- Before: a subscribed share viewer is authorized but never reached. -/
theorem viewer_missed :
    let viewer : UserState := ⟨false, true, true⟩
    authorized viewer = true ∧ reached recipientBefore viewer = false := by
  decide

end ChatDelivery
end SyrusModel
