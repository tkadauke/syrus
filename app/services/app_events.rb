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

  # Two statements rather than one atomic RETURNING-style query: this
  # must stay portable across SQLite (dev/test) and MySQL (prod), and
  # nothing here needs strict per-call uniqueness -- the column only ever
  # increases, so a rare read-after-a-concurrent-write race just assigns
  # two broadcasts the same sequence number, which the frontend already
  # treats as "not a gap" (duplicates are ignored, never mistaken for one).
  def self.next_sequence(user)
    User.where(id: user.id).update_all("app_event_sequence = app_event_sequence + 1")
    User.where(id: user.id).pick(:app_event_sequence).to_i
  end
end
