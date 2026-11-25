module Metrics
  # Runtime Image Service gauges: stored images by state, retained rollback
  # images, failed cleanup, worker cache footprint, and recent pull outcomes.
  # Sampled centrally into the cache like Metrics::FleetSampler; operation
  # counters are declared in RuntimeImages::Telemetry.
  class RuntimeImageSampler
    CACHE_KEY = "syrus:metrics:runtime_image_sample".freeze
    CACHE_TTL = 5.minutes

    def self.declare_metrics!
      Syrus::Metrics.declare do
        gauge :runtime_images, tags: %i[state],
              comment: "Runtime images by state: pending, available, revoked, deleted, retained, cleanup_failed " \
                       "(GLOBAL -- aggregate with max by, never sum)"
        gauge :runtime_image_cache_bytes, tags: %i[state],
              comment: "Bytes of runtime images held in worker caches by entry state (GLOBAL -- aggregate with max by, never sum)"
        gauge :runtime_image_build_requests, tags: %i[state],
              comment: "Runtime image build requests by state (GLOBAL -- aggregate with max by, never sum)"
        gauge :runtime_image_build_oldest_queued_seconds,
              comment: "Age of the oldest queued runtime image build request, 0 when none (GLOBAL -- aggregate with max by, never sum)"
        gauge :runtime_image_build_stale_attempts,
              comment: "Active build attempts past their lease or runtime ceiling that recovery has not reaped (GLOBAL -- aggregate with max by, never sum)"
        gauge :runtime_image_pulls_24h, tags: %i[outcome],
              comment: "Worker image cache lookups and pulls in the last 24 hours by outcome (GLOBAL -- aggregate with max by, never sum)"
      end
    end
    declare_metrics!
    Syrus::Metrics.register_sampler(self)

    def self.sample!(...) = new(...).sample!
    def self.refresh_gauges!(...) = new(...).refresh_gauges!

    def sample!
      payload = {
        images: guard("images", {}) { image_counts },
        cache: guard("cache", {}) { RuntimeImageCacheEntry.group(:state).sum(:size_bytes) },
        pulls: guard("pulls", {}) { RuntimeImagePullEvent.since(24.hours.ago).group(:outcome).count },
        builds: guard("builds", {}) { build_counts },
        build_oldest_queued: guard("build queue age", 0) { RuntimeImages::Builds::Health.new.oldest_queued_seconds.to_i },
        build_stale: guard("stale attempts", 0) { RuntimeImages::Builds::Health.new.stale_attempts.count }
      }
      Rails.cache.write(CACHE_KEY, payload, expires_in: CACHE_TTL)
      payload
    end

    def refresh_gauges!
      payload = Rails.cache.read(CACHE_KEY)
      if payload.blank?
        %i[syrus_runtime_images syrus_runtime_image_cache_bytes syrus_runtime_image_pulls_24h syrus_runtime_image_build_requests].each { |metric| clear(metric) }
        %i[syrus_runtime_image_build_oldest_queued_seconds syrus_runtime_image_build_stale_attempts].each { |metric| clear(metric) }
        return false
      end
      replace(:syrus_runtime_images, payload[:images], :state)
      replace(:syrus_runtime_image_cache_bytes, payload[:cache], :state)
      replace(:syrus_runtime_image_pulls_24h, payload[:pulls], :outcome)
      replace(:syrus_runtime_image_build_requests, payload[:builds], :state)
      Syrus::Metrics.gauge(:syrus_runtime_image_build_oldest_queued_seconds).set(payload[:build_oldest_queued].to_i)
      Syrus::Metrics.gauge(:syrus_runtime_image_build_stale_attempts).set(payload[:build_stale].to_i)
      true
    end

    private

    def image_counts
      counts = RuntimeImage.group(:availability).count
      RuntimeImage::AVAILABILITIES.index_with { |state| counts.fetch(state, 0) }.merge(
        "retained" => RuntimeImage.where(retention_state: "retained").where.not(availability: "deleted").count,
        "cleanup_failed" => RuntimeImage.cleanup_failed.count
      )
    end

    def build_counts
      counts = RuntimeImageBuildRequest.group(:state).count
      RuntimeImageBuildRequest::STATES.index_with { |state| counts.fetch(state, 0) }
    end

    def replace(metric, values, tag)
      clear(metric)
      gauge = Syrus::Metrics.gauge(metric)
      Hash(values).each { |key, value| gauge.set(value.to_i, tags: { tag => key.to_s }) }
    end

    def clear(metric)
      gauge = Syrus::Metrics.gauge(metric)
      gauge.samples.each { |tags, _value| gauge.clear(tags: tags) }
    end

    def guard(what, fallback)
      yield
    rescue StandardError => e
      Rails.logger.warn("[Metrics::RuntimeImageSampler] could not sample #{what}: #{e.class}: #{e.message}")
      fallback
    end
  end
end
