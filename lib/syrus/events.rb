module Syrus
  # Publishes domain events to plugin subscribers.
  #
  # Core publishes from explicit call sites -- `Syrus::Events.publish(...)`
  # written where the decision is made -- rather than from model callbacks, so
  # the event list is greppable and reviewable rather than emergent.
  #
  # Delivery:
  #
  #   :async (default)  enqueued onto the subscribing plugin's home_queue. A
  #                     subscriber failure never fails the publisher.
  #   :inline           run synchronously inside the publishing call, for
  #                     subscribers that need something which will not survive
  #                     the turn -- a file in a workspace that is about to be
  #                     torn down, say. Still isolated: a raising subscriber is
  #                     logged, not propagated.
  module Events
    # Declared rather than free-form so a typo fails loudly at publish time
    # instead of silently reaching nobody, and so the catalog is discoverable.
    EVENTS = {
      "job.created"           => :async,
      "job.state_changed"     => :async,
      "job.closed"            => :async,
      "job.approved"          => :async,
      "workflow.started"      => :async,
      "workflow.finished"     => :async,
      "run.finished"          => :async,
      "step.grader.completed" => :inline,
      "step.command.completed" => :inline,
      "repository.created"    => :async,
      "repository.archived"   => :async,
      "repository.destroyed"  => :async
    }.freeze

    class UnknownEvent < StandardError; end

    module_function

    def known?(name) = EVENTS.key?(name.to_s)

    def delivery_for(name) = EVENTS.fetch(name.to_s)

    def publish(name, **payload)
      name = name.to_s
      raise UnknownEvent, "Unknown domain event: #{name.inspect}. Valid: #{EVENTS.keys.inspect}" unless known?(name)

      event = Syrus::DomainEvent.new(name: name, payload: payload)

      if delivery_for(name) == :inline
        deliver_inline(event)
      else
        deliver_async(event)
      end

      event
    end

    # [[provider, method_name], ...] for one event name.
    def subscribers_for(name)
      name = name.to_s

      Syrus::PluginRegistry.providers_for(:domain_subscriber).filter_map do |provider|
        method_name = subscriptions_for(provider)[name]
        next if method_name.blank?

        [ provider, method_name ]
      end
    end

    def subscriptions_for(provider)
      return {} unless provider.respond_to?(:subscriptions)

      Array(provider.subscriptions).to_h.transform_keys(&:to_s)
    rescue StandardError => e
      Rails.logger.error("[Syrus::Events] #{provider} raised resolving subscriptions: #{e.class}: #{e.message}")
      {}
    end

    def deliver_inline(event)
      subscribers_for(event.name).each do |provider, method_name|
        PerformanceLogging.plugin_call(extension_point: :domain_subscriber, provider: provider, operation: event.name) do
          provider.public_send(method_name, event)
        end
      rescue StandardError => e
        Rails.logger.error("[Syrus::Events] #{provider}##{method_name} failed on #{event.name}: #{e.class}: #{e.message}")
      end
    end

    def deliver_async(event)
      subscribers_for(event.name).each do |provider, _method_name|
        DomainEventJob.set(queue: queue_for(provider)).perform_later(event.name, event.payload.deep_stringify_keys, provider.to_s)
      rescue StandardError => e
        # Enqueue can fail when the queue backend is unavailable (asset
        # precompile, a partially migrated database). An observer missing an
        # event must not take down the thing being observed.
        Rails.logger.error("[Syrus::Events] could not enqueue #{event.name} for #{provider}: #{e.class}: #{e.message}")
      end
    end

    def queue_for(provider)
      manifest = Syrus::PluginRegistry.all_plugins.find do |candidate|
        Array(candidate.provides[:domain_subscriber]).include?(provider)
      end
      home = manifest&.home_queue
      home.nil? || home == :default ? DomainEventJob.queue_name : home.to_s
    end
  end
end
