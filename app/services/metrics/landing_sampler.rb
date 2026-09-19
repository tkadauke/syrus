module Metrics
  # The landing queue and run-throughput metrics: is Syrus landing work, and
  # how fast. `docs/metrics-catalog.md` had only Solid Queue health and
  # product-usage metrics before this; the landing queue and overall run
  # throughput had no exported Prometheus metrics at all (see
  # docs/plans/complete/prometheus-dashboard.md, "Product throughput").
  #
  # /metrics is currently served by the **web** role only (see
  # config/syrus_docs/metrics.md); every event this class counts -- a Run
  # finishing, a Job landing, a Solid Queue job completing -- happens on a
  # **worker** process. A counter or histogram mutated in-process at the
  # event site, or even just in-process during #sample! (which itself runs
  # from a worker), would sit invisible in that worker's heap forever: the
  # web process rendering /metrics has a completely separate registry. So all
  # eight metrics are cache-mediated, the same shape QueueSampler already
  # uses for its gauges, just extended to cover counters and histograms too:
  #
  # * **Gauges** (job_state, landing_queue_depth, queue_table_rows) are
  #   aggregate facts about the whole install. #sample! writes the latest
  #   snapshot to Rails.cache; #refresh_gauges! `set`s them from the cache on
  #   the scrape path, with no query -- idempotent no matter how many times
  #   or which process calls it.
  # * **Counters and histograms** (runs_total, run_duration_seconds,
  #   jobs_landed_total, time_to_land_seconds, queue_completed_total) can't
  #   use `set`: Counter/Histogram only accumulate (#increment/#observe), by
  #   design, so the true count of what happened has to live somewhere both
  #   processes can reach. #sample! keeps a cursor per event source so each
  #   newly-finished Run/Job/queue-execution is folded into a cumulative
  #   snapshot exactly once, and writes that snapshot to its own cache key.
  #   #refresh_gauges! reads it back and calls Counter#reconcile!/
  #   Histogram#reconcile! to overwrite this process's local instrument to
  #   match -- the same `set`-like idempotency as the gauges above, just
  #   expressed as "catch up to the known total" instead of "assign the
  #   known value", because that's the only vocabulary a monotonic
  #   instrument has.
  class LandingSampler
    CACHE_KEY = "syrus:metrics:landing_sample".freeze
    CURSOR_CACHE_KEY = "syrus:metrics:landing_sample:cursor".freeze
    TOTALS_CACHE_KEY = "syrus:metrics:landing_sample:totals".freeze
    # Same reasoning as QueueSampler::CACHE_TTL: longer than the sampling
    # period so one missed tick does not blank the dashboard, short enough
    # that a dead sampler stops reporting rather than showing stale numbers.
    CACHE_TTL = 5.minutes
    # The cursor and the cumulative totals must both outlive a single missed
    # tick (or the gauge cache expiring) without losing track of "already
    # instrumented" -- losing the cursor would replay history or skip
    # whatever finished while it was gone; losing the totals would make a
    # monotonic counter appear to drop, which #reconcile!'s backward guard
    # then refuses to apply, silently freezing it instead. Either failure
    # needs real cache downtime measured in hours to happen at all.
    CURSOR_TTL = 1.day

    # RSpec/Prometheus-client defaults top out near 10s, which buckets nearly
    # every real Run into the last, useless bin (see
    # docs/plans/complete/prometheus-dashboard.md's API sketch).
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
    Syrus::Metrics.register_sampler(self)

    def self.sample!(...) = new(...).sample!
    def self.refresh_gauges!(...) = new(...).refresh_gauges!

    def initialize(source: LandingSource.new, queue_source: Metrics::QueueSource.new)
      @source = source
      @queue_source = queue_source
    end

    # Runs on the recurring schedule (SampleGlobalMetricsJob). Instruments
    # every Run/Job/queue-execution event newly finished since the last tick
    # into the cumulative totals snapshot, then writes both that and the
    # gauge sample to the cache for #refresh_gauges! to pick up -- possibly
    # in a different process entirely.
    def sample!
      now = Time.current
      cursor = read_cursor
      totals = read_totals

      instrument_runs!(cursor, totals, now)
      instrument_landed_jobs!(cursor, totals, now)
      instrument_completed_queue_executions!(cursor, totals, now)

      write_cursor(cursor)
      write_totals(totals)

      payload = {
        sampled_at: now,
        job_state: guard("job state", {}) { source.job_state_counts },
        landing_queue_depth: guard("landing queue depth", {}) { source.landing_queue_blocked_reason_counts },
        queue_table_rows: guard("queue table rows", 0) { queue_source.table_rows }
      }
      Rails.cache.write(CACHE_KEY, payload, expires_in: CACHE_TTL)
      payload
    end

    # Called on the scrape path (MetricsController, memoized for a few
    # seconds). Sets the global gauges from the cached sample and reconciles
    # every counter/histogram to the cached cumulative totals -- one indexed
    # cache read per key, no query, safe to call from any process and any
    # number of times.
    def refresh_gauges!
      payload = Rails.cache.read(CACHE_KEY)
      totals = read_totals
      return false if payload.blank? && totals.blank?

      if payload.present?
        set_each(:syrus_job_state, payload[:job_state], :state)
        set_each(:syrus_landing_queue_depth, payload[:landing_queue_depth], :blocked_reason)
        Syrus::Metrics.gauge(:syrus_queue_table_rows).set(payload[:queue_table_rows].to_i)
      end

      reconcile_totals!(totals) if totals.present?

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
    def instrument_runs!(cursor, totals, now)
      after = cursor["runs_through"]
      return cursor["runs_through"] = now.iso8601(6) if after.nil?

      rows = guard("finished runs", []) { source.finished_runs(after: Time.iso8601(after), through: now) }

      running_totals = (totals["runs_total"] ||= {})
      rows.each do |state, trigger_kind, *|
        key = { state: state, trigger_kind: trigger_kind }
        running_totals[key] = (running_totals[key] || 0) + 1
      end

      durations = rows.filter_map { |_state, _trigger_kind, started_at, finished_at, step_kind|
        [ { step_kind: step_kind }, finished_at - started_at ] if started_at && finished_at && step_kind
      }
      totals["run_duration_seconds"] = merge_histogram(:syrus_run_duration_seconds, totals["run_duration_seconds"], durations)

      cursor["runs_through"] = now.iso8601(6)
    end

    def instrument_landed_jobs!(cursor, totals, now)
      after = cursor["jobs_through"]
      return cursor["jobs_through"] = now.iso8601(6) if after.nil?

      rows = guard("landed jobs", []) { source.landed_jobs(after: Time.iso8601(after), through: now) }
      totals["jobs_landed_total"] = (totals["jobs_landed_total"] || 0) + rows.size

      lead_times = rows.filter_map { |created_at, finished_at| [ {}, finished_at - created_at ] if created_at && finished_at }
      totals["time_to_land_seconds"] = merge_histogram(:syrus_time_to_land_seconds, totals["time_to_land_seconds"], lead_times)

      cursor["jobs_through"] = now.iso8601(6)
    end

    def instrument_completed_queue_executions!(cursor, totals, now)
      after = cursor["queue_completed_through"]
      return cursor["queue_completed_through"] = now.iso8601(6) if after.nil?

      completed = guard("completed queue executions", 0) {
        queue_source.completed_count(after: Time.iso8601(after), through: now)
      }
      totals["queue_completed_total"] = (totals["queue_completed_total"] || 0) + completed.to_i

      cursor["queue_completed_through"] = now.iso8601(6)
    end

    # Folds new (tags, value) observations into a cached cumulative histogram
    # snapshot by replaying them through a scratch instrument seeded with the
    # previous snapshot via Histogram#reconcile!. This reuses #observe's own
    # bucket math instead of duplicating it here, which matters: the live
    # instrument's bucket keys are Floats (Histogram#initialize), and a
    # hand-rolled Integer-keyed bucket hash would silently miss every lookup
    # on render (1.eql?(1.0) is false in Ruby, so a plain `{}` -- not
    # `Hash.new(0)` -- accumulator keyed by the wrong numeric type would
    # render blank buckets instead of raising).
    def merge_histogram(metric_name, previous_totals, observations)
      scratch = Syrus::Metrics::Histogram.new(Syrus::Metrics.histogram(metric_name).definition)
      Hash(previous_totals).each { |tags, entry| scratch.reconcile!(entry, tags: tags) }
      observations.each { |tags, value| scratch.observe(value, tags: tags) }
      scratch.samples.to_h
    end

    def reconcile_totals!(totals)
      Hash(totals["runs_total"]).each { |tags, total| Syrus::Metrics.counter(:syrus_runs_total).reconcile!(total, tags: tags) }
      Hash(totals["run_duration_seconds"]).each { |tags, entry|
        Syrus::Metrics.histogram(:syrus_run_duration_seconds).reconcile!(entry, tags: tags)
      }
      Hash(totals["time_to_land_seconds"]).each { |tags, entry|
        Syrus::Metrics.histogram(:syrus_time_to_land_seconds).reconcile!(entry, tags: tags)
      }
      if totals["jobs_landed_total"]
        Syrus::Metrics.counter(:syrus_jobs_landed_total).reconcile!(totals["jobs_landed_total"].to_i)
      end
      if totals["queue_completed_total"]
        Syrus::Metrics.counter(:syrus_queue_completed_total).reconcile!(totals["queue_completed_total"].to_i)
      end
    end

    def read_cursor
      Rails.cache.read(CURSOR_CACHE_KEY) || {}
    end

    def write_cursor(cursor)
      Rails.cache.write(CURSOR_CACHE_KEY, cursor, expires_in: CURSOR_TTL)
    end

    def read_totals
      Rails.cache.read(TOTALS_CACHE_KEY) || {}
    end

    def write_totals(totals)
      Rails.cache.write(TOTALS_CACHE_KEY, totals, expires_in: CURSOR_TTL)
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
