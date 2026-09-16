module Syrus
  module Metrics
    # Backs the plugin `metrics do gauge :x do ... end end` declarative form.
    # One of these is built per sampled gauge definition (see
    # Syrus::PluginApi::Definition#metrics) and registered into
    # Syrus::Metrics's sampler registry exactly like a core sampler class, so
    # a plugin author never hand-writes a sampler for the common case of
    # "read one aggregate value on a timer" -- no tick_interval, on_tick, or
    # on_metrics_scrape boilerplate. See Metrics::QueueSampler for when a full
    # sampler class (declared with `sampler <class>` instead) is still the
    # right tool: several gauges computed off one query pass, or a counter
    # that needs cursor-based cumulative logic.
    class SampledGauge
      CACHE_TTL = 5.minutes

      def initialize(definition:)
        @definition = definition
      end

      # Keyed on the metric's own fully-qualified name, so a plugin
      # re-declaring on re-enable (or a dev reload) replaces this sampler's
      # registry entry instead of accumulating a duplicate.
      def sampler_key = "sampled_gauge:#{@definition.name}"

      def sample!
        value = @definition.sample_block.call
        Rails.cache.write(cache_key, value, expires_in: CACHE_TTL)
        value
      rescue StandardError => e
        Rails.logger.warn("[Syrus::Metrics::SampledGauge] #{@definition.name} sample failed: #{e.class}: #{e.message}")
        nil
      end

      def refresh_gauges!
        value = Rails.cache.read(cache_key)
        return false if value.nil?

        Syrus::Metrics.gauge(@definition.name).set(value)
        true
      end

      private

      def cache_key = "syrus:metrics:sampled_gauge:#{@definition.name}"
    end
  end
end
