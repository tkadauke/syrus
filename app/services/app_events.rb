class AppEvents
  # Every event broadcast to a user's app channel is stamped with a
  # per-user monotonically increasing `sequence`, so the frontend can
  # detect a dropped delivery (a sequence gap) and recover with one
  # targeted refresh instead of trusting delivery order or wall-clock
  # `occurred_at`. `revision`, when the caller has one (a Revisionable
  # resource), lets the frontend's normalized entity store ignore a
  # duplicate or out-of-order event outright instead of merely detecting
  # a gap. See app/frontend/lib/appEvents.ts and entityStore.ts.
  def self.broadcast(user:, type:, resource:, id: nil, changed: [], payload: nil, revision: nil, occurred_at: Time.current)
    event = {
      type: type.to_s,
      resource: resource.to_s,
      id: id,
      sequence: next_sequence(user),
      changed: Array(changed).map(&:to_s),
      occurred_at: occurred_at.iso8601(3)
    }
    event[:revision] = revision unless revision.nil?
    event[:payload] = payload if payload

    AppUserChannel.broadcast_to(user, event.as_json)
  end

  # Two statements rather than one atomic RETURNING-style query, to stay
  # portable across SQLite (dev/test) and MySQL (prod) -- but they must run
  # inside one transaction, not as independent calls. An `UPDATE` always
  # takes a lock covering the updated row for the rest of the transaction
  # (an exclusive row lock under MySQL/InnoDB; SQLite's single writer-lock
  # covers the whole database once a transaction has written). Wrapping the
  # update and the follow-up read in the same transaction means no other
  # call can modify this counter in between: the `pick` below is guaranteed
  # to see exactly the value *this* call's `update_all` produced, not a
  # value that raced ahead of it. Without the transaction, two concurrent
  # broadcasts for the same user could both read the same post-increment
  # value and be stamped with an identical `sequence` -- and since the
  # frontend drops a repeated/non-advancing `sequence` outright as a
  # duplicate (see trackAppEventSequence in app/frontend/lib/appEvents.ts),
  # that would silently discard one of the two broadcasts instead of
  # merely mis-detecting a duplicate.
  def self.next_sequence(user)
    User.transaction do
      User.where(id: user.id).update_all("app_event_sequence = app_event_sequence + 1")
      User.where(id: user.id).pick(:app_event_sequence).to_i
    end
  end
end
