module Syrus
  module Plugin
    # Interface for plugin-provided external messaging platforms (Discord,
    # etc.). Registering a class here makes PlatformDelivery::Registry.for
    # resolve it by .platform_key, PlatformIdentity#platform accept that key
    # as a valid value, and (when the plugin exposes an inbound listener)
    # boot start it via PlatformDelivery::Registry.start_connectors!.
    #
    # Usage:
    #   class MyPlugin::PlatformAdapter
    #     include Syrus::Plugin::PlatformDelivery
    #
    #     def self.platform_key = "discord"
    #     def self.connector_job_class = MyPlugin::GatewayJob
    #
    #     def deliver(message:, platform_identity:)
    #       # send `message` out to `platform_identity.external_id`
    #     end
    #   end
    #
    #   Syrus::PluginRegistry.register(
    #     name: "my-plugin", version: "1.0.0",
    #     provides: { platform_delivery: MyPlugin::PlatformAdapter }
    #   )
    module PlatformDelivery
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def platform_key
          raise NotImplementedError, "#{self} must implement .platform_key"
        end

        # Optional: the PlatformPollingJob subclass that runs this platform's
        # inbound connector (Gateway/long-poll job). Return nil when the
        # platform has no inbound listener to start at boot.
        def connector_job_class
          nil
        end
      end

      def deliver(message:, platform_identity:)
        raise NotImplementedError, "#{self.class}#deliver is required"
      end
    end
  end
end
