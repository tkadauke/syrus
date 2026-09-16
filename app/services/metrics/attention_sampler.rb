module Metrics
  # Wires up two metrics from the attention/escalation ladder
  # (workflow-engine-v3) that existed as fully-working services with no
  # exporter: `Metrics::EscalationsPerLanding` (the plan's "one metric" --
  # escalations per landing, trending down) and the open queue depth from
  # `AttentionItem` itself.
  #
  # Both are plain GLOBAL gauges sampled on a timer into the cache, the same
  # shape Metrics::QueueSampler/ResilienceSampler use -- `EscalationsPerLanding.call`
  # and the `AttentionItem` group-count are aggregate queries over the whole
  # install, exactly the kind that must not run on the scrape path.
  #
  # `escalations_per_landing_ratio` has one thing neither of those sibling
  # samplers needs: `Metrics::EscalationsPerLanding::Result#ratio` is
  # documented as `nil` when nothing landed in the window (see its class
  # comment -- an infinity would read as a number, "no landings" is the
  # honest answer). Rendering that as `0` would misreport a quiet window as
  # "the ladder is working great," and letting a *stale* ratio from an
  # earlier tick linger in the live Gauge instrument past the cache TTL would
  # be worse -- a confidently wrong number outliving the data that produced
  # it. So `#refresh_gauges!` clears the gauge outright (`Gauge#clear`)
  # whenever the cached sample has no ratio to report, rather than calling
  # `#set` with anything -- the same "absent means not applicable, zero means
  # observed-and-empty" distinction `Metrics::ProductUsage`'s preset and this
  # sampler's own `attention_items_open_total` both rely on, just reached by
  # subtraction instead of never adding the key in the first place.
  class AttentionSampler
    CACHE_KEY = "syrus:metrics:attention_sample".freeze
    # Same reasoning as QueueSampler::CACHE_TTL: longer than the sampling
    # period so one missed tick does not blank the dashboard, short enough
    # that a genuinely dead sampler stops reporting rather than showing
    # stale numbers forever.
    CACHE_TTL = 5.minutes

    def self.declare_metrics!
      Syrus::Metrics.declare do
        gauge :escalations_per_landing_ratio,
              comment: "Escalations opened per landing over the trailing window -- the Workflow Engine V3 " \
                       "\"one metric,\" trending down (GLOBAL -- aggregate with max by, never sum). Omitted " \
                       "when no landings occurred in the window rather than reporting a misleading 0 or a " \
                       "stale prior ratio."
        gauge :attention_items_open_total, tags: %i[problem_code],
              comment: "Currently open, unexpired AttentionItems by problem code (GLOBAL -- aggregate with " \
                       "max by, never sum)"
      end
    end
    declare_metrics!

    def self.sample!(...) = new(...).sample!
    def self.refresh_gauges!(...) = new(...).refresh_gauges!

    def initialize(escalations_per_landing: Metrics::EscalationsPerLanding)
      @escalations_per_landing = escalations_per_landing
    end

    # Runs on the recurring schedule (SampleGlobalMetricsJob). Writes the
    # sample to the cache; does not touch the gauges -- see
    # Metrics::QueueSampler for why.
    def sample!
      payload = {
        sampled_at: Time.current,
        ratio: guard("escalations per landing", nil) { escalations_per_landing.call.ratio },
        open_by_problem_code: guard("open attention items", {}) { open_attention_item_counts }
      }
      Rails.cache.write(CACHE_KEY, payload, expires_in: CACHE_TTL)
      payload
    end

    # Called on the scrape path. Reads the cached sample -- one indexed key
    # lookup, not an aggregate query -- and sets/clears the gauges from it.
    #
    # The ratio gauge is cleared both when this tick's sample has no ratio
    # (no landings in the window) *and* when the cache itself has expired --
    # a dead sampler must not leave the last real ratio rendering forever,
    # since that reads as "still healthy" through the exact outage this
    # gauge exists to surface.
    def refresh_gauges!
      payload = Rails.cache.read(CACHE_KEY)
      ratio = payload.present? ? payload[:ratio] : nil
      ratio_gauge = Syrus::Metrics.gauge(:syrus_escalations_per_landing_ratio)

      if ratio
        ratio_gauge.set(ratio)
      else
        ratio_gauge.clear
      end

      return false if payload.blank?

      set_each(:syrus_attention_items_open_total, payload[:open_by_problem_code], :problem_code)

      true
    end

    private

    attr_reader :escalations_per_landing

    def open_attention_item_counts
      AttentionItem.open_decisions.unexpired.group(:problem_code).count
    end

    def set_each(metric, values, tag)
      gauge = Syrus::Metrics.gauge(metric)
      Hash(values).each { |label, value| gauge.set(value, tags: { tag => label }) }
    end

    # One unreachable source costs its own gauge, not the whole sample.
    def guard(what, fallback)
      yield
    rescue StandardError => e
      Rails.logger.warn("[Metrics::AttentionSampler] could not sample #{what}: #{e.class}: #{e.message}")
      fallback
    end
  end
end
