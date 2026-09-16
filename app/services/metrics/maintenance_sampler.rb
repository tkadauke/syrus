module Metrics
  # The maintenance/pruner metric group: is every recurring maintenance job
  # (pruners chief among them) still actually succeeding, is the table that
  # already blew up once (`provider_sessions`) growing again, and is the
  # auto-retry budget-exemption bug documented in CLAUDE.md ("Failure
  # resilience") recurring.
  #
  # Motivating incident: `provider_sessions` reached 6.0 GB, rows dating back
  # over a month, because `prune_provider_sessions` had silently stopped --
  # invisible outside a Rails console until someone went looking by hand. The
  # same shape as every other incident this metrics effort has instrumented.
  #
  # `recurring_job_last_success_seconds` needs its own durable high-water mark
  # (`LAST_SUCCESS_CACHE_KEY`, `LAST_SUCCESS_TTL`) rather than just reading
  # `SolidQueue::Job` fresh every tick: Solid Queue prunes finished job rows
  # after `SolidQueue.clear_finished_jobs_after` (1 day by default), which is
  # far shorter than the staleness this gauge exists to catch (the motivating
  # incident ran over a month). Sampling the current maximum every tick and
  # only ever moving the cached high-water mark forward means a real success
  # is never lost to that pruning window, the same way `Metrics::LandingSampler`
  # keeps a durable cumulative total that solid_queue_jobs' own pruning cannot
  # see through.
  #
  # `auto_retry_attempts_total` is a cursor-based counter for the same reason
  # as `Metrics::LandingSampler`'s counters: the event (an AutoRetryAttempt
  # settling) happens on a worker, but /metrics is served by web, so the
  # cumulative total has to live in the cache, not in either process' local
  # instrument.
  #
  # Split across two sources the same way Metrics::LandingSampler splits
  # across Metrics::LandingSource/Metrics::QueueSource: `source`
  # (Metrics::MaintenanceSource) reads ordinary ActiveRecord tables
  # (AutoRetryAttempt, ProviderSession) and is exercised directly in specs;
  # `queue_source` (Metrics::QueueSource) reads solid_queue_jobs, which does
  # not exist in the test database (see CLAUDE.md), so it is exercised
  # through a fake there.
  class MaintenanceSampler
    CACHE_KEY = "syrus:metrics:maintenance_sample".freeze
    # Same reasoning as QueueSampler::CACHE_TTL: longer than the sampling
    # period so one missed tick does not blank the dashboard, short enough
    # that a dead sampler stops reporting rather than showing stale numbers.
    CACHE_TTL = 5.minutes

    LAST_SUCCESS_CACHE_KEY = "syrus:metrics:maintenance_sample:last_success".freeze
    # Long enough that this cache expiring is not itself a plausible failure
    # mode within the staleness windows this metric exists to catch.
    LAST_SUCCESS_TTL = 100.days

    CURSOR_CACHE_KEY = "syrus:metrics:maintenance_sample:cursor".freeze
    TOTALS_CACHE_KEY = "syrus:metrics:maintenance_sample:totals".freeze
    CURSOR_TTL = 1.day

    def self.declare_metrics!
      Syrus::Metrics.declare do
        gauge :recurring_job_last_success_seconds, tags: %i[job],
              comment: "Seconds since a config/recurring.yml job last completed successfully -- a job " \
                       "that stops succeeding grows this instead of vanishing (GLOBAL -- aggregate with " \
                       "max by, never sum)"
        gauge :provider_sessions_bytes,
              comment: "Total transcript_jsonl bytes across all provider_sessions rows (GLOBAL -- " \
                       "aggregate with max by, never sum)"
        gauge :provider_sessions_rows,
              comment: "Total provider_sessions row count (GLOBAL -- aggregate with max by, never sum)"
        counter :auto_retry_attempts_total, tags: %i[skip_reason],
                comment: "Auto-retry attempts by settled outcome -- \"none\" means the retry was " \
                         "performed, any other value is a bounded AutoRetryAttempt skip-reason category " \
                         "(see AutoRetryAttempt.skip_reason_category)"
      end
    end
    declare_metrics!

    def self.sample!(...) = new(...).sample!
    def self.refresh_gauges!(...) = new(...).refresh_gauges!

    def initialize(source: MaintenanceSource.new, queue_source: Metrics::QueueSource.new)
      @source = source
      @queue_source = queue_source
    end

    # Runs on the recurring schedule (SampleGlobalMetricsJob). Advances the
    # last-success high-water mark and the auto-retry cumulative totals, then
    # writes the scrape-path payload to the cache.
    def sample!
      now = Time.current

      cursor = read_cursor
      totals = read_totals
      instrument_auto_retry_attempts!(cursor, totals, now)
      write_cursor(cursor)
      write_totals(totals)

      last_success = merge_last_success(
        read_last_success,
        guard("recurring job last success", {}) { queue_source.recurring_job_last_success_at }
      )
      write_last_success(last_success)

      payload = {
        sampled_at: now,
        last_success: last_success,
        provider_sessions_bytes: guard("provider sessions bytes", 0) { source.provider_sessions_bytes },
        provider_sessions_rows: guard("provider sessions rows", 0) { source.provider_sessions_rows }
      }
      Rails.cache.write(CACHE_KEY, payload, expires_in: CACHE_TTL)
      payload
    end

    # Called on the scrape path. Sets gauges from the cached sample and
    # reconciles the counter to the cached cumulative totals -- indexed cache
    # reads only, safe from any process, any number of times.
    def refresh_gauges!
      payload = Rails.cache.read(CACHE_KEY)
      totals = read_totals
      return false if payload.blank? && totals.blank?

      if payload.present?
        now = Time.current
        gauge = Syrus::Metrics.gauge(:syrus_recurring_job_last_success_seconds)
        Hash(payload[:last_success]).each do |job, at|
          gauge.set((now - at).round, tags: { job: job }) if at
        end

        Syrus::Metrics.gauge(:syrus_provider_sessions_bytes).set(payload[:provider_sessions_bytes].to_i)
        Syrus::Metrics.gauge(:syrus_provider_sessions_rows).set(payload[:provider_sessions_rows].to_i)
      end

      reconcile_totals!(totals) if totals.present?

      true
    end

    private

    attr_reader :source, :queue_source

    def instrument_auto_retry_attempts!(cursor, totals, now)
      after = cursor["auto_retry_attempts_through"]
      return cursor["auto_retry_attempts_through"] = now.iso8601(6) if after.nil?

      reasons = guard("settled auto-retry attempts", []) {
        source.settled_auto_retry_attempts(after: Time.iso8601(after), through: now)
      }

      running_totals = (totals["auto_retry_attempts_total"] ||= {})
      reasons.each do |reason|
        category = AutoRetryAttempt.skip_reason_category(reason)
        running_totals[category] = (running_totals[category] || 0) + 1
      end

      cursor["auto_retry_attempts_through"] = now.iso8601(6)
    end

    def reconcile_totals!(totals)
      Hash(totals["auto_retry_attempts_total"]).each do |category, total|
        Syrus::Metrics.counter(:syrus_auto_retry_attempts_total).reconcile!(total, tags: { skip_reason: category })
      end
    end

    # Only ever advances: a per-job success timestamp we have already
    # observed must never regress just because Solid Queue pruned the row
    # that most recently proved it, or because a tick's query happened to
    # come back empty for a job that is fine.
    def merge_last_success(previous, observed)
      merged = previous.dup
      Hash(observed).each do |job, at|
        next unless at

        existing = merged[job]
        merged[job] = at if existing.nil? || at > existing
      end
      merged
    end

    def read_last_success
      Hash(Rails.cache.read(LAST_SUCCESS_CACHE_KEY)).transform_values { |at| at.is_a?(String) ? Time.iso8601(at) : at }
    end

    def write_last_success(last_success)
      Rails.cache.write(LAST_SUCCESS_CACHE_KEY, last_success.transform_values(&:iso8601), expires_in: LAST_SUCCESS_TTL)
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
      Rails.logger.warn("[Metrics::MaintenanceSampler] could not sample #{what}: #{e.class}: #{e.message}")
      fallback
    end
  end
end
