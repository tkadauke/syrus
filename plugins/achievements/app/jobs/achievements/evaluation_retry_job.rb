module Achievements
  # Re-runs evaluation for an event whose first, inline attempt hit a transient
  # failure. Core's subscriber boundary deliberately swallows subscriber errors
  # (a subscriber never fails the publisher), so the plugin owns its retry: this
  # job raises, and PluginJob's retry_on re-enqueues it with backoff. Evaluation
  # is idempotent, so re-running it is always safe.
  class EvaluationRetryJob < Syrus::Host::PluginJob
    plugin :achievements

    def perform(event_name, payload, occurred_at)
      return unless Achievements.enabled?

      event = Achievements::ReplayedEvent.new(name: event_name, payload: payload, occurred_at: Time.zone.parse(occurred_at.to_s))
      Achievements::Evaluation.call(event)
    end
  end
end
