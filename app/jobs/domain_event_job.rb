# Delivers one async domain event to one plugin subscriber.
#
# Per-subscriber rather than per-event so a slow or failing subscriber cannot
# delay or break delivery to the others, and so each runs on its own plugin's
# home queue.
class DomainEventJob < ApplicationJob
  def perform(event_name, payload, provider_name)
    provider, method_name = Syrus::Events.subscribers_for(event_name)
      .find { |candidate, _| candidate.to_s == provider_name }

    # The plugin may have been disabled, or gone unhealthy, between publish and
    # delivery. Dropping the event is correct: a disabled plugin should not be
    # running behavior.
    return if provider.nil?

    event = Syrus::DomainEvent.new(name: event_name, payload: payload || {})

    PerformanceLogging.plugin_call(extension_point: :domain_subscriber, provider: provider, operation: event_name) do
      provider.public_send(method_name, event)
    end
  end
end
