module Metrics
  # Samples the Solid Queue tables into gauges.
  #
  # These are **global** facts -- one truth about the whole cluster, not a
  # per-pod value -- so they are sampled once by a recurring job, cached, and
  # rendered by whichever process serves /metrics. Every pod therefore reports
  # the same number, which means dashboards must aggregate them with
  # `max by (queue) (...)` and never `sum`. The `syrus_global_` prefix exists to
  # make that rule legible from the metric name alone.
  #
  # The queries are why this is a timed sampler rather than something the scrape
  # path runs: they are aggregates over tables with hundreds of thousands of
  # rows, and a /metrics endpoint that runs them gets slow at precisely the
  # moment those tables are the problem.
  #
  # Motivating incident: a 2,715-job polling backlog whose oldest job was 190
  # minutes old, invisible to every health check an operator would think to run
  # (see docs/plans/complete/prometheus-dashboard.md).
  class QueueSampler
    CACHE_KEY = "syrus:metrics:queue_sample".freeze
    # Longer than the sampling period so one missed run does not blank the
    # dashboard, short enough that a genuinely dead sampler stops reporting
    # rather than showing stale numbers forever.
    CACHE_TTL = 5.minutes

    # A method rather than a bare block so it can be re-run after
    # Syrus::Metrics.reset! without reloading this file, which would warn about
    # redefined constants. Invoked from the class body, so simply loading this
    # class is what declares the metrics -- see config/initializers/metrics.rb
    # for why that needs help under lazy loading.
    def self.declare_metrics!
      Syrus::Metrics.declare do
        gauge :global_queue_ready_count, tags: %i[queue],
              comment: "Jobs ready to be claimed (GLOBAL -- aggregate with max by, never sum)"
        gauge :global_queue_oldest_age_seconds, tags: %i[queue],
              comment: "Age of the oldest ready job (GLOBAL -- aggregate with max by, never sum)"
        gauge :global_queue_claimed_count, tags: %i[queue],
              comment: "Jobs currently claimed by a worker (GLOBAL -- aggregate with max by)"
        gauge :global_queue_blocked_count,
              comment: "Executions blocked on a concurrency limit (GLOBAL -- aggregate with max by)"
        gauge :global_queue_failed_count, tags: %i[job_class],
              comment: "Failed executions awaiting retry or discard (GLOBAL -- aggregate with max by)"
        gauge :global_queue_orphaned_rows,
              comment: "Unfinished job rows with no execution row -- unreachable by work and by the " \
                       "finished-job pruner (GLOBAL -- aggregate with max by)"
        gauge :global_queue_sample_age_seconds,
              comment: "Age of the cached queue sample; large means the sampler has stopped"
      end
    end
    declare_metrics!
    Syrus::Metrics.register_sampler(self)

    def self.sample!(...) = new(...).sample!
    def self.refresh_gauges!(...) = new(...).refresh_gauges!

    def initialize(source: QueueSource.new)
      @source = source
    end

    # Runs on the recurring schedule. Writes the sample to the cache; does not
    # touch the gauges, because the process that samples is usually not the
    # process that serves /metrics.
    def sample!
      payload = collect
      Rails.cache.write(CACHE_KEY, payload, expires_in: CACHE_TTL)
      payload
    end

    # Called on the scrape path. Reads the cached sample -- one indexed key
    # lookup, not an aggregate query -- and sets the gauges from it.
    #
    # The cache is DB-backed (solid_cache), so this is not literally zero
    # database work. The invariant that matters is that no *aggregate* query
    # runs per scrape; MetricsController additionally memoizes within a short
    # window so a scrape storm collapses onto one lookup.
    def refresh_gauges!
      payload = Rails.cache.read(CACHE_KEY)
      return false if payload.blank?

      set_each(:syrus_global_queue_ready_count, payload[:ready], :queue)
      set_each(:syrus_global_queue_oldest_age_seconds, payload[:oldest_age], :queue)
      set_each(:syrus_global_queue_claimed_count, payload[:claimed], :queue)
      set_each(:syrus_global_queue_failed_count, payload[:failed], :job_class)

      Syrus::Metrics.gauge(:syrus_global_queue_blocked_count).set(payload[:blocked].to_i)
      Syrus::Metrics.gauge(:syrus_global_queue_orphaned_rows).set(payload[:orphaned].to_i)

      if (sampled_at = payload[:sampled_at])
        Syrus::Metrics.gauge(:syrus_global_queue_sample_age_seconds).set((Time.current - sampled_at).round)
      end

      true
    end

    private

    attr_reader :source

    def set_each(metric, values, tag)
      gauge = Syrus::Metrics.gauge(metric)
      Hash(values).each { |label, value| gauge.set(value, tags: { tag => label }) }
    end

    def collect
      now = Time.current
      {
        sampled_at: now,
        ready: guard("ready counts", {}) { source.ready_counts },
        oldest_age: guard("oldest ages", {}) { ages_from(source.oldest_ready_at, now) },
        claimed: guard("claimed counts", {}) { source.claimed_counts },
        blocked: guard("blocked count", 0) { source.blocked_count },
        failed: guard("failed counts", {}) { source.failed_counts },
        orphaned: guard("orphaned rows", 0) { source.orphaned_rows }
      }
    end

    # Age, not just depth. Depth alone is ambiguous -- 500 fast jobs is healthy,
    # 50 stuck ones is not -- and age is the number that tells them apart.
    def ages_from(timestamps, now)
      Hash(timestamps).transform_values { |at| at ? (now - at).round : 0 }
    end

    # One unreachable table costs its own gauge, not the whole sample.
    def guard(what, fallback)
      yield
    rescue StandardError => e
      Rails.logger.warn("[Metrics::QueueSampler] could not sample #{what}: #{e.class}: #{e.message}")
      fallback
    end
  end
end
