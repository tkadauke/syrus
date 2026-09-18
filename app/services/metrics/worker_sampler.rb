module Metrics
  # The "Workers and admission" metric group from docs/plans/prometheus-dashboard.md:
  # is the fleet keeping up, and is any single worker overloaded while others
  # sit idle (the motivating incident: "one worker at 3277m and another idle
  # at 51m", invisible until someone went looking by hand).
  #
  # Same cache-mediated shape as Metrics::QueueSampler and
  # Metrics::LandingSampler, mixed for the same reason LandingSampler mixes
  # them: worker_cpu_percent/worker_memory_percent/active_agent_runs/
  # max_concurrent_agent_runs are GLOBAL gauges (aggregate facts, `set` from a
  # cached sample on the scrape path); workflow_step_duration_seconds is a
  # histogram, which can only accumulate, so it goes through the same cursor +
  # cumulative-snapshot dance LandingSampler uses for run_duration_seconds.
  #
  # `syrus_admission_decisions_total{decision}` is the other metric in this
  # plan section, but it is genuinely per-process (see
  # config/syrus_docs/metrics.md's "Aggregating" section) -- it is declared
  # and incremented directly inside WorkflowAdmissionBudget/RunHostAdmission
  # at the moment a decision is made, not sampled here.
  class WorkerSampler
    CACHE_KEY = "syrus:metrics:worker_sample".freeze
    CURSOR_CACHE_KEY = "syrus:metrics:worker_sample:cursor".freeze
    TOTALS_CACHE_KEY = "syrus:metrics:worker_sample:totals".freeze
    CACHE_TTL = 5.minutes
    CURSOR_TTL = 1.day

    # Same spread as LandingSampler::RUN_DURATION_BUCKETS -- a Step's
    # wall-clock lives in the same seconds-to-hours range a Run's does.
    WORKFLOW_STEP_DURATION_BUCKETS = [ 1, 5, 15, 60, 300, 900, 1800, 3600, 7200 ].freeze

    def self.declare_metrics!
      Syrus::Metrics.declare do
        gauge :worker_cpu_percent, tags: %i[worker_storage_key],
              comment: "Worker host CPU utilization from the latest health sample (GLOBAL -- aggregate with max by, never sum)"
        gauge :worker_memory_percent, tags: %i[worker_storage_key],
              comment: "Worker host memory utilization from the latest health sample (GLOBAL -- aggregate with max by, never sum)"
        gauge :worker_disk_percent, tags: %i[worker_storage_key],
              comment: "Worker host data-root disk utilization from the latest health sample (GLOBAL -- aggregate with max by, never sum)"
        gauge :active_agent_runs,
              comment: "Currently running agentic Runs, subject to the global concurrency cap (GLOBAL -- aggregate with max by, never sum)"
        gauge :max_concurrent_agent_runs,
              comment: "Configured ceiling on concurrent agent Runs, 0 meaning unlimited, so the dashboard panel " \
                       "shows capacity alongside utilization (GLOBAL -- aggregate with max by, never sum)"
        histogram :workflow_step_duration_seconds, buckets: WORKFLOW_STEP_DURATION_BUCKETS, tags: %i[kind],
                  comment: "Step wall clock from start to finish, spanning every Run attempt within the Step"
      end
    end
    declare_metrics!
    Syrus::Metrics.register_sampler(self)

    def self.sample!(...) = new(...).sample!
    def self.refresh_gauges!(...) = new(...).refresh_gauges!

    def initialize(source: WorkerSource.new)
      @source = source
    end

    # Runs on the recurring schedule (SampleGlobalMetricsJob).
    def sample!
      now = Time.current
      cursor = read_cursor
      totals = read_totals

      instrument_finished_steps!(cursor, totals, now)

      write_cursor(cursor)
      write_totals(totals)

      payload = {
        sampled_at: now,
        worker_cpu_percent: guard("worker cpu percent", {}) { source.worker_cpu_percentages },
        worker_memory_percent: guard("worker memory percent", {}) { source.worker_memory_percentages },
        worker_disk_percent: guard("worker disk percent", {}) { source.worker_disk_percentages },
        active_agent_runs: guard("active agent runs", 0) { source.active_agent_run_count },
        max_concurrent_agent_runs: guard("max concurrent agent runs", 0) { source.max_concurrent_agent_runs }
      }
      Rails.cache.write(CACHE_KEY, payload, expires_in: CACHE_TTL)
      payload
    end

    # Called on the scrape path.
    def refresh_gauges!
      payload = Rails.cache.read(CACHE_KEY)
      totals = read_totals
      return false if payload.blank? && totals.blank?

      if payload.present?
        set_each(:syrus_worker_cpu_percent, payload[:worker_cpu_percent], :worker_storage_key)
        set_each(:syrus_worker_memory_percent, payload[:worker_memory_percent], :worker_storage_key)
        set_each(:syrus_worker_disk_percent, payload[:worker_disk_percent], :worker_storage_key)
        Syrus::Metrics.gauge(:syrus_active_agent_runs).set(payload[:active_agent_runs].to_i)
        Syrus::Metrics.gauge(:syrus_max_concurrent_agent_runs).set(payload[:max_concurrent_agent_runs].to_i)
      end

      reconcile_totals!(totals) if totals.present?

      true
    end

    private

    attr_reader :source

    def set_each(metric, values, tag)
      gauge = Syrus::Metrics.gauge(metric)
      Hash(values).each { |label, value| gauge.set(value, tags: { tag => label }) }
    end

    # Bootstraps the cursor to "now" without instrumenting existing history,
    # the same instinct as LandingSampler#instrument_runs!.
    def instrument_finished_steps!(cursor, totals, now)
      after = cursor["steps_through"]
      return cursor["steps_through"] = now.iso8601(6) if after.nil?

      rows = guard("finished steps", []) { source.finished_steps(after: Time.iso8601(after), through: now) }

      durations = rows.filter_map { |kind, started_at, finished_at|
        [ { kind: kind }, finished_at - started_at ] if started_at && finished_at && kind
      }
      totals["workflow_step_duration_seconds"] =
        merge_histogram(:syrus_workflow_step_duration_seconds, totals["workflow_step_duration_seconds"], durations)

      cursor["steps_through"] = now.iso8601(6)
    end

    # See LandingSampler#merge_histogram for why this replays through a
    # scratch instrument instead of hand-rolling the bucket math.
    def merge_histogram(metric_name, previous_totals, observations)
      scratch = Syrus::Metrics::Histogram.new(Syrus::Metrics.histogram(metric_name).definition)
      Hash(previous_totals).each { |tags, entry| scratch.reconcile!(entry, tags: tags) }
      observations.each { |tags, value| scratch.observe(value, tags: tags) }
      scratch.samples.to_h
    end

    def reconcile_totals!(totals)
      Hash(totals["workflow_step_duration_seconds"]).each do |tags, entry|
        Syrus::Metrics.histogram(:syrus_workflow_step_duration_seconds).reconcile!(entry, tags: tags)
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
      Rails.logger.warn("[Metrics::WorkerSampler] could not sample #{what}: #{e.class}: #{e.message}")
      fallback
    end
  end
end
