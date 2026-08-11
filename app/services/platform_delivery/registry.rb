module PlatformDelivery
  class Registry
    ADAPTERS = {
      "web" => WebAdapter,
      "telegram" => TelegramAdapter
    }.freeze

    @runtime_adapters = {}

    class << self
      def register(platform, adapter_class)
        @runtime_adapters = @runtime_adapters.merge(platform.to_s => adapter_class)
      end

      def for(platform)
        adapter_class = adapter_class_for(platform) || BaseAdapter
        adapter_class.new
      end

      def registered?(platform)
        adapter_class_for(platform).present?
      end

      # Starts every plugin-registered platform's inbound connector job
      # (Gateway/long-poll) at boot, when the plugin is enabled and exposes
      # one. Core adapters (web, telegram) are not plugins and keep starting
      # via PlatformPollingJob's own inheritance-based registry.
      def start_connectors!
        Syrus::PluginRegistry.providers_for(:platform_delivery).filter_map { |provider| start_connector(provider) }
      rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError => e
        Rails.logger.warn("PlatformDelivery::Registry.start_connectors! skipped: #{e.message}")
        []
      end

      private

      def start_connector(provider)
        job_class = provider.connector_job_class
        return unless job_class

        PlatformPollingJob.start_one(job_class)
      rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError => e
        Rails.logger.warn("PlatformDelivery::Registry.start_connector skipped for #{provider}: #{e.message}")
        nil
      end

      def adapter_class_for(platform)
        @runtime_adapters[platform.to_s] || ADAPTERS[platform.to_s] || plugin_adapters[platform.to_s]
      end

      def plugin_adapters
        Syrus::PluginRegistry.providers_for(:platform_delivery).index_by { |provider| provider.platform_key.to_s }
      end
    end
  end
end
