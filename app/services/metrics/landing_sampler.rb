module Metrics
  # The landing queue and run-throughput metrics: is Syrus landing work, and
  # how fast. `docs/metrics-catalog.md` had only Solid Queue health and
  # product-usage metrics before this; the landing queue and overall run
  # throughput had no exported Prometheus metrics at all (see
  # docs/plans/prometheus-dashboard.md, "Product throughput").
  #
  # Two different instrumentation shapes live in this one class, both for the
  # same reason QueueSampler's gauges do: /metrics is currently served by the
  # **web** role only (see config/syrus_docs/metrics.md), while every event
  # here -- a Run finishing, a Job landing, a Solid Queue job completing --
  # happens on a **worker** process. A counter incremented in-process at the
  # event site would sit invisible in the worker's heap forever.
  #
  # * **Gauges** (job_state, landing_queue_depth, queue_table_rows) are
  #   aggregate facts about the whole install. Sampled on a timer into
  #   Rails.cache, same as QueueSampler; #refresh_gauges! sets them from the
  #   cache on the scrape path with no query.
  # * **Counters and histograms** (runs_total, run_duration_seconds,
  #   jobs_landed_total, time_to_land_seconds, queue_completed_total) count
  #   *events*, which a periodic gauge-style sample cannot represent without
  #   either double-counting or losing the underlying distribution. Instead
  #   #sample! keeps a cursor per event source and instruments each
  #   newly-finished Run/Job/queue-execution exactly once, the same tick that
  #   samples the gauges. That keeps the instrument semantics honest
  #   (monotonic, real per-observation histogram buckets) while still never
  #   running the underlying query from the scrape path.
  class LandingSampler
    CACHE_KEY = "syrus:metrics:landing_sample".freeze
    CURSOR_CACHE_KEY = "syrus:metrics:landing_sample:cursor".freeze
    # Same reasoning as QueueSampler::CACHE_TTL: longer than the sampling
    # period so one missed tick does not blank the dashboard, short enough
    # that a dead sampler stops reporting rather than showing stale numbers.
    CACHE_TTL = 5.minutes
    # The cursor must outlive a single missed tick (or the gauge cache
    # expiring) without ever losing track of "already instrumented" -- losing
    # it would either replay history into the counters or silently skip
    # whatever finished while it was gone.
    CURSOR_TTL = 1.day

    # RSpec/Prometheus-client defaults top out near 10s, which buckets nearly
    # every real Run into the last, useless bin (see
    # docs/plans/prometheus-dashboard.md's API sketch).
    RUN_DURATION_BUCKETS = [ 1, 5, 15, 60, 300, 900, 1800, 3600, 7200 ].freeze
    # A landed Job's lead time ranges from minutes to days once a blocked
    # approval is included, so this needs its own, wider exponential spread.
    TIME_TO_LAND_BUCKETS = [ 30, 60, 300, 900, 1800, 3600, 7200, 14_400, 28_800, 86_400, 259_200 ].freeze

    def self.declare_metrics!
      Syrus::Metrics.declare do
        counter :jobs_landed_total,
                comment: "Jobs whose PR reached the base branch"
        gauge :job_state, tags: %i[state],
              comment: "Jobs grouped by state (GLOBAL -- aggregate with max by, never sum)"
        gauge :landing_queue_depth, tags: %i[blocked_reason],
              comment: "Approved/landing Jobs by why they are not landing yet, \"none\" meaning eligible " \
                       "(GLOBAL -- aggregate with max by, never sum)"
        histogram :time_to_land_seconds, buckets: TIME_TO_LAND_BUCKETS,
                  comment: "Wall clock from Job creation to landing"
        counter :runs_total, tags: %i[state trigger_kind],
                comment: "Runs by terminal state"
        histogram :run_duration_seconds, buckets: RUN_DURATION_BUCKETS, tags: %i[step_kind],
                  comment: "Run wall clock by step kind"
        counter :queue_completed_total,
                comment: "Solid Queue executions that finished -- pairs with syrus_global_queue_ready_count " \
                         "for the queue-starved alert"
        gauge :queue_table_rows,
              comment: "Total Solid Queue row count across every table, the table-level companion to " \
                       "syrus_global_queue_orphaned_rows (GLOBAL -- aggregate with max by, never sum)"
      end
    end
    declare_metrics!

    def self.sample!(...) = new(...).sample!
    def self.refresh_gauges!(...) = new(...).refresh_gauges!

    def initialize(source: LandingSource.new, queue_source: Metrics::QueueSource.new)
      @source = source
      @queue_source = queue_source
    end

    # Runs on the recurring schedule (SampleGlobalMetricsJob). Instruments
    # every Run/Job/queue-execution event newly finished since the last tick,
    # then writes the gauge sample the scrape path reads.
    def sample!
      now = Time.current
      cursor = read_cursor

      instrument_runs!(cursor, now)
      instrument_landed_jobs!(cursor, now)
      instrument_completed_queue_executions!(cursor, now)
      write_cursor(cursor)

      payload = {
        sampled_at: now,
        job_state: guard("job state", {}) { source.job_state_counts },
        landing_queue_depth: guard("landing queue depth", {}) { source.landing_queue_blocked_reason_counts },
        queue_table_rows: guard("queue table rows", 0) { queue_source.table_rows }
      }
      Rails.cache.write(CACHE_KEY, payload, expires_in: CACHE_TTL)
      payload
    end

    # Called on the scrape path. Sets the global gauges from the cached
    # sample -- one indexed key lookup, not an aggregate query. Counters and
    # histograms need no refresh here: #sample! already instrumented them
    # in-process, and the registry renders live instrument state directly.
    def refresh_gauges!
      payload = Rails.cache.read(CACHE_KEY)
      return false if payload.blank?

      set_each(:syrus_job_state, payload[:job_state], :state)
      set_each(:syrus_landing_queue_depth, payload[:landing_queue_depth], :blocked_reason)
      Syrus::Metrics.gauge(:syrus_queue_table_rows).set(payload[:queue_table_rows].to_i)

      true
    end

    private

    attr_reader :source, :queue_source

    def set_each(metric, values, tag)
      gauge = Syrus::Metrics.gauge(metric)
      Hash(values).each { |label, value| gauge.set(value, tags: { tag => label }) }
    end

    # Bootstraps the cursor to "now" without instrumenting anything the first
    # time a key is seen, the same instinct as ProductUsage's zero-preset:
    # counting starts from deploy, not backfilled from the Job/Run tables'
    # entire history.
    def instrument_runs!(cursor, now)
      after = cursor["runs_through"]
      return cursor["runs_through"] = now.iso8601(6) if after.nil?

      rows = guard("finished runs", []) { source.finished_runs(after: Time.iso8601(after), through: now) }
      counter = Syrus::Metrics.counter(:syrus_runs_total)
      histogram = Syrus::Metrics.histogram(:syrus_run_duration_seconds)

      rows.each do |state, trigger_kind, started_at, finished_at, step_kind|
        counter.increment(tags: { state: state, trigger_kind: trigger_kind })
        histogram.observe(finished_at - started_at, tags: { step_kind: step_kind }) if started_at && finished_at && step_kind
      end

      cursor["runs_through"] = now.iso8601(6)
    end

    def instrument_landed_jobs!(cursor, now)
      after = cursor["jobs_through"]
      return cursor["jobs_through"] = now.iso8601(6) if after.nil?

      rows = guard("landed jobs", []) { source.landed_jobs(after: Time.iso8601(after), through: now) }
      counter = Syrus::Metrics.counter(:syrus_jobs_landed_total)
      histogram = Syrus::Metrics.histogram(:syrus_time_to_land_seconds)

      rows.each do |created_at, finished_at|
        counter.increment
        histogram.observe(finished_at - created_at) if created_at && finished_at
      end

      cursor["jobs_through"] = now.iso8601(6)
    end

    def instrument_completed_queue_executions!(cursor, now)
      after = cursor["queue_completed_through"]
      return cursor["queue_completed_through"] = now.iso8601(6) if after.nil?

      completed = guard("completed queue executions", 0) {
        queue_source.completed_count(after: Time.iso8601(after), through: now)
      }
      Syrus::Metrics.counter(:syrus_queue_completed_total).increment(by: completed) if completed.to_i.positive?

      cursor["queue_completed_through"] = now.iso8601(6)
    end

    def read_cursor
      Rails.cache.read(CURSOR_CACHE_KEY) || {}
    end

    def write_cursor(cursor)
      Rails.cache.write(CURSOR_CACHE_KEY, cursor, expires_in: CURSOR_TTL)
    end

    # One unreachable source costs its own gauge/counter, not the whole tick.
    def guard(what, fallback)
      yield
    rescue StandardError => e
      Rails.logger.warn("[Metrics::LandingSampler] could not sample #{what}: #{e.class}: #{e.message}")
      fallback
    end
  end
end
