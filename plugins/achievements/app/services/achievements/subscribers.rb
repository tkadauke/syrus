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
    end
  end
end
