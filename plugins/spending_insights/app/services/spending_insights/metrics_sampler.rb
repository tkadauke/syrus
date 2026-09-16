module SpendingInsights
  # Samples Run#cost_usd into a global, cumulative counter for /metrics.
  #
  # A Run's cost is finalized on whichever worker process ran its agent
  # invocation (see AgentProviders::Base#record_result!), but /metrics is
  # served by the web role only (config/syrus_docs/metrics.md, "Scope") --
  # incrementing a counter directly at that call site would sit invisible in
  # the worker's own registry forever. So this follows Metrics::LandingSampler's
  # shape: #sample! runs on the shared control-plane tick (registered via the
  # manifest's `metrics do ... sampler MetricsSampler end` -- see
  # Syrus::PluginApi::Definition#metrics -- rather than a plugin-owned
  # tick_interval/on_tick), folding every newly-finished Run's cost into a
  # cumulative cache-mediated total exactly once (a cursor over `finished_at`,
  # set exactly once per Run and never revised), and #refresh_gauges! --
  # called from that same shared registry on the /metrics scrape path --
  # reconciles this process's counter to that known total.
  class MetricsSampler
    CACHE_KEY = "spending_insights:metrics:run_cost_sample".freeze
    CURSOR_CACHE_KEY = "spending_insights:metrics:run_cost_sample:cursor".freeze
    TOTALS_CACHE_KEY = "spending_insights:metrics:run_cost_sample:totals".freeze
    CACHE_TTL = 5.minutes
    CURSOR_TTL = 1.day

    def self.sample! = new.sample!
    def self.refresh_gauges! = new.refresh_gauges!

    def sample!
      now = Time.current
      cursor = read_cursor
      totals = read_totals

      instrument_finished_runs!(cursor, totals, now)

      write_cursor(cursor)
      write_totals(totals)
      true
    end

    def refresh_gauges!
      totals = read_totals
      return false if totals.blank?

      counter = Syrus::Metrics.counter(:syrus_spending_insights_run_cost_usd_total)
      Hash(totals["run_cost_usd_total"]).each { |tags, total| counter.reconcile!(total, tags: tags) }
      true
    end

    private

    # Bootstraps to "now" the first time this ever runs, rather than
    # backfilling every historical Run -- the same instinct as
    # Metrics::ProductUsage's zero-preset and Metrics::LandingSampler's cursor.
    def instrument_finished_runs!(cursor, totals, now)
      after = cursor["through"]
      return cursor["through"] = now.iso8601(6) if after.nil?

      rows = guard("finished runs", []) { finished_runs(after: Time.iso8601(after), through: now) }

      running_totals = (totals["run_cost_usd_total"] ||= {})
      rows.each do |provider, trigger_kind, cost_usd|
        key = { provider: provider, trigger_kind: trigger_kind }
        running_totals[key] = (running_totals[key] || 0.0) + cost_usd.to_f
      end

      cursor["through"] = now.iso8601(6)
    end

    def finished_runs(after:, through:)
      Run.terminal
         .where(finished_at: after...through)
         .where.not(cost_usd: nil)
         .pluck(:agent_provider, :trigger_kind, :cost_usd)
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

    # One unreachable source costs this tick's sample, not the whole tick.
    def guard(what, fallback)
      yield
    rescue StandardError => e
      Rails.logger.warn("[SpendingInsights::MetricsSampler] could not sample #{what}: #{e.class}: #{e.message}")
      fallback
    end
  end
end
