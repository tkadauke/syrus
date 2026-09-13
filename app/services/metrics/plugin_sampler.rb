module Metrics
  # Which plugins are installed, and which of those are switched on.
  #
  # This is what disambiguates the two ways a feature can report nothing. A
  # plugin's own metrics follow `while_enabled` semantics, so a disabled plugin
  # emits no series at all -- identical, from a dashboard, to a plugin that is
  # enabled and simply unused. Without this gauge a product decision made on
  # that silence would err in the expensive direction: concluding nobody wants a
  # feature that was merely switched off.
  #
  #   syrus_plugin_enabled{plugin="video_walkthroughs"} 0   installed, switched off
  #   (no series at all)                                    not installed
  #
  # Sampled rather than read on the scrape path: PluginRegistry.all_plugins
  # annotates each manifest from the plugin_records table, and /metrics must not
  # run queries.
  class PluginSampler
    CACHE_KEY = "syrus:metrics:plugin_sample".freeze
    CACHE_TTL = 5.minutes

    def self.declare_metrics!
      Syrus::Metrics.declare do
        gauge :global_plugin_enabled, tags: %i[plugin],
              comment: "1 when an installed plugin is enabled, 0 when it is off " \
                       "(GLOBAL -- aggregate with max by)"
      end
    end
    declare_metrics!

    def self.sample! = new.sample!
    def self.refresh_gauges! = new.refresh_gauges!

    def sample!
      payload = collect
      Rails.cache.write(CACHE_KEY, payload, expires_in: CACHE_TTL)
      payload
    end

    def refresh_gauges!
      payload = Rails.cache.read(CACHE_KEY)
      return false if payload.blank?

      gauge = Syrus::Metrics.gauge(:syrus_global_plugin_enabled)
      payload.each { |plugin, enabled| gauge.set(enabled ? 1 : 0, tags: { plugin: plugin }) }
      true
    end

    private

    def collect
      Syrus::PluginRegistry.all_plugins.to_h { |manifest| [ manifest.name, manifest.enabled? ] }
    rescue StandardError => e
      Rails.logger.warn("[Metrics::PluginSampler] could not sample plugins: #{e.class}: #{e.message}")
      {}
    end
  end
end
