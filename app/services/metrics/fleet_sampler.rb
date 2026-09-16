module Metrics
  # The "Fleet" metric group from docs/plans/prometheus-dashboard.md: what is
  # actually running right now, across pods and subprocesses. Both metrics
  # here are plain GLOBAL gauges -- no counter/histogram half like
  # Metrics::WorkerSampler needs, so no cursor bookkeeping is required.
  class FleetSampler
    CACHE_KEY = "syrus:metrics:fleet_sample".freeze
    CACHE_TTL = 5.minutes

    def self.declare_metrics!
      Syrus::Metrics.declare do
        gauge :instance_versions, tags: %i[role version],
              comment: "Live pods by role and git SHA -- two versions during a rollout is expected " \
                       "(GLOBAL -- aggregate with max by, never sum)"
        gauge :spawned_processes, tags: %i[kind state],
              comment: "Spawned subprocesses running or recently finished, by kind and state " \
                       "(GLOBAL -- aggregate with max by, never sum)"
      end
    end
    declare_metrics!
    Syrus::Metrics.register_sampler(self)

    def self.sample!(...) = new(...).sample!
    def self.refresh_gauges!(...) = new(...).refresh_gauges!

    def initialize(source: FleetSource.new)
      @source = source
    end

    # Runs on the recurring schedule (SampleGlobalMetricsJob). Writes the
    # sample to the cache; does not touch the gauges -- see
    # Metrics::QueueSampler for why.
    def sample!
      payload = {
        instance_versions: guard("instance versions", {}) { source.instance_version_counts },
        spawned_processes: guard("spawned processes", {}) { source.spawned_process_counts }
      }
      Rails.cache.write(CACHE_KEY, payload, expires_in: CACHE_TTL)
      payload
    end

    # Called on the scrape path.
    def refresh_gauges!
      payload = Rails.cache.read(CACHE_KEY)
      return false if payload.blank?

      set_pair_each(:syrus_instance_versions, payload[:instance_versions], :role, :version)
      set_pair_each(:syrus_spawned_processes, payload[:spawned_processes], :kind, :state)

      true
    end

    private

    attr_reader :source

    def set_pair_each(metric, values, tag_a, tag_b)
      gauge = Syrus::Metrics.gauge(metric)
      Hash(values).each { |(a, b), value| gauge.set(value, tags: { tag_a => a, tag_b => b }) }
    end

    # One unreachable source costs its own gauge, not the whole sample.
    def guard(what, fallback)
      yield
    rescue StandardError => e
      Rails.logger.warn("[Metrics::FleetSampler] could not sample #{what}: #{e.class}: #{e.message}")
      fallback
    end
  end
end
