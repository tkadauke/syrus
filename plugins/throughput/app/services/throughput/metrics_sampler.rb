module Throughput
  # Global, install-wide landing-attempt counters for /metrics.
  #
  # This is deliberately NOT Throughput::MetricContract. That contract is
  # per-repository and computed fresh on every API request (see
  # docs/syrus_docs/repository_throughput_metrics.md, "Query shape") --
  # exactly the kind of request-time aggregate /metrics must not run (see
  # config/syrus_docs/metrics.md). This class instead follows
  # Metrics::LandingSampler's shape: registers via the manifest's
  # `metrics do ... sampler MetricsSampler end` (see
  # Syrus::PluginApi::Definition#metrics) rather than a plugin-owned
  # tick_interval/on_tick, so #sample! runs on the shared control-plane tick
  # and folds newly-finished landing attempts into a cumulative,
  # cache-mediated total (a cursor over `finished_at`, set exactly once and
  # never revised); #refresh_gauges!, called from that same shared registry
  # on the /metrics scrape path, reconciles this process's counters to that
  # total -- because a Workflow or MergeTrain finishes on a worker process,
  # and /metrics is served by web only.
  #
  # "Landing unit" mirrors MetricContract's own vocabulary: one auto_merge
  # Workflow lands one Job, one merge_train lands every member Job in it.
  # `landing_units_total` counts attempts (one per unit, regardless of size);
  # `jobs_landed_total` counts the Jobs those attempts actually landed.
  class MetricsSampler
    CACHE_KEY = "throughput:metrics:landing_sample".freeze
    CURSOR_CACHE_KEY = "throughput:metrics:landing_sample:cursor".freeze
    TOTALS_CACHE_KEY = "throughput:metrics:landing_sample:totals".freeze
    CACHE_TTL = 5.minutes
    CURSOR_TTL = 1.day

    def self.sample! = new.sample!
    def self.refresh_gauges! = new.refresh_gauges!

    def sample!
      now = Time.current
      cursor = read_cursor
      totals = read_totals

      instrument_auto_merges!(cursor, totals, now)
      instrument_merge_trains!(cursor, totals, now)

      write_cursor(cursor)
      write_totals(totals)
      true
    end

    def refresh_gauges!
      totals = read_totals
      return false if totals.blank?

      units = Syrus::Metrics.counter(:syrus_throughput_landing_units_total)
      Hash(totals["landing_units_total"]).each { |tags, total| units.reconcile!(total, tags: tags) }

      if totals["jobs_landed_total"]
        Syrus::Metrics.counter(:syrus_throughput_jobs_landed_total).reconcile!(totals["jobs_landed_total"].to_i)
      end
      true
    end

    private

    def instrument_auto_merges!(cursor, totals, now)
      after = cursor["auto_merge_through"]
      return cursor["auto_merge_through"] = now.iso8601(6) if after.nil?

      count = guard("succeeded auto_merge workflows", 0) {
        Workflow.where(trigger_kind: "auto_merge", state: "succeeded")
                .where(finished_at: Time.iso8601(after)...now)
                .count
      }
      increment_unit_totals!(totals, unit_type: "auto_merge", attempts: count, jobs: count)

      cursor["auto_merge_through"] = now.iso8601(6)
    end

    def instrument_merge_trains!(cursor, totals, now)
      after = cursor["merge_train_through"]
      return cursor["merge_train_through"] = now.iso8601(6) if after.nil?

      trains = guard("succeeded merge trains", []) {
        MergeTrain.where(state: "succeeded").where(finished_at: Time.iso8601(after)...now).pluck(:id)
      }
      jobs_landed = trains.empty? ? 0 : guard("merge train members", 0) {
        MergeTrainMember.where(merge_train_id: trains).count
      }
      increment_unit_totals!(totals, unit_type: "merge_train", attempts: trains.size, jobs: jobs_landed)

      cursor["merge_train_through"] = now.iso8601(6)
    end

    def increment_unit_totals!(totals, unit_type:, attempts:, jobs:)
      return if attempts.zero? && jobs.zero?

      units = (totals["landing_units_total"] ||= {})
      key = { unit_type: unit_type }
      units[key] = (units[key] || 0) + attempts

      totals["jobs_landed_total"] = (totals["jobs_landed_total"] || 0) + jobs
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

    # One unreachable source costs its own contribution to this tick, not the
    # whole tick.
    def guard(what, fallback)
      yield
    rescue StandardError => e
      Rails.logger.warn("[Throughput::MetricsSampler] could not sample #{what}: #{e.class}: #{e.message}")
      fallback
    end
  end
end
