module Achievements
  # Observes core through the public domain-event boundary; nothing is patched
  # onto Job, Epic, or any other core model. Subscriptions come from the event
  # adapters, so only events the evaluators understand are requested. Async
  # delivery is dropped by core while the plugin is disabled, and the guard
  # below covers a delivery already in flight.
  class Subscribers
    include Syrus::Plugin::DomainSubscriber

    def self.subscriptions
      EventAdapters.event_names.index_with { :on_event }
    end

    def self.on_event(event)
      return unless Achievements.enabled?

      Achievements::Evaluation.call(event)
    rescue StandardError => error
      # Core logs and swallows subscriber failures, which would lose the unlock
      # for good (there is no backfill). Hand the event to a plugin job that
      # retries with backoff; evaluation is idempotent.
      Rails.logger.error("[achievements] #{event.name} evaluation failed, scheduling retry: #{error.class}: #{error.message}")
      Achievements::EvaluationRetryJob.perform_later(event.name, event.payload.deep_stringify_keys, event.occurred_at.iso8601(6))
    end
  end
end
