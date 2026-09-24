class AppEvents
  # Deliveries counted by `resource` -- a closed, bounded set of model-ish
  # names ("job", "workflow", "step", "run", "chat", "epic", "repository",
  # "notification", ...), the same set app/frontend/lib/appEvents.ts's
  # `queryKeysFor` switches on -- so it stays a legitimate cardinality-
  # allowlist entry rather than an identifier. This is the "event" half of
  # EPIC-392's event-to-request amplification signal: paired with
  # App::JobWorkflowsSnapshotCache's `detail_snapshot_requests_total`, an
  # operator can compare how many events a resource generates against how
  # many requests those events actually cause.
  def self.declare_metrics!
    Syrus::Metrics.declare do
      counter :app_events_delivered_total, tags: %i[resource], cluster: true,
              comment: "Application events broadcast to a user channel or a Job/Chat resource channel, by resource, " \
                       "from every process -- the event half of the event-to-request amplification signal " \
                       "(GLOBAL -- aggregate with max by, never sum; EPIC-392). See Metrics::AmplificationSampler."
    end
  end
  declare_metrics!

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
    record_delivery(resource)
  end

  # Detailed per-resource broadcasts, delivered only to JobChannel/ChatChannel
  # subscribers actively observing that one Job or Chat (see
  # app/channels/job_channel.rb, chat_channel.rb) -- never to AppUserChannel.
  # ActionCable drops a broadcast to a stream with no live subscribers, so a
  # resource nobody has open costs nothing beyond the pub/sub publish; this is
  # the mechanism that keeps high-churn payloads (Workflow/Step/Run field
  # patches, chat message tails) off the global per-user channel every other
  # tab that user has open would otherwise receive regardless of what it's
  # looking at.
  #
  # Deliberately omits `sequence`: the frontend's per-user gap detection only
  # tracks the sequenced AppUserChannel stream (see trackAppEventSequence in
  # app/frontend/lib/appEvents.ts), and an event without a `sequence` is
  # always applied directly rather than participating in gap/duplicate
  # detection. That's safe here because these events are independently
  # idempotent and order-independent: entity-store patches merge by
  # `revision` (see entityStore.ts#upsertEntity), and chat message tails
  # merge by message id (see replaceMessageTail). Continuity after a
  # reconnect is instead handled by a bounded, resource-scoped refetch when
  # the JobChannel/ChatChannel subscription itself reconnects (see
  # subscribeToJobResourceEvents/subscribeToChatResourceEvents).
  def self.broadcast_job_resource(job_id:, type:, resource:, id:, changed: [], payload: nil, revision: nil, occurred_at: Time.current)
    ActionCable.server.broadcast(
      JobChannel.stream_name(job_id),
      resource_event(type: type, resource: resource, id: id, changed: changed, payload: payload, revision: revision, occurred_at: occurred_at)
    )
    record_delivery(resource)
  end

  def self.broadcast_chat_resource(chat_session_id:, type:, resource:, id:, changed: [], payload: nil, revision: nil, occurred_at: Time.current)
    ActionCable.server.broadcast(
      ChatChannel.stream_name(chat_session_id),
      resource_event(type: type, resource: resource, id: id, changed: changed, payload: payload, revision: revision, occurred_at: occurred_at)
    )
    record_delivery(resource)
  end

  def self.record_delivery(resource)
    Syrus::Metrics.counter(:syrus_app_events_delivered_total).increment(tags: { resource: resource.to_s })
  end
  private_class_method :record_delivery

  def self.resource_event(type:, resource:, id:, changed:, payload:, revision:, occurred_at:)
    event = {
      type: type.to_s,
      resource: resource.to_s,
      id: id,
      changed: Array(changed).map(&:to_s),
      occurred_at: occurred_at.iso8601(3)
    }
    event[:revision] = revision unless revision.nil?
    event[:payload] = payload if payload
    event.as_json
  end
  private_class_method :resource_event

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
  private_class_method :next_sequence
end
