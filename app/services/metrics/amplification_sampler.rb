module Metrics
  # The frontend event-amplification "one metric": how much backend request
  # work does an application event cause, by resource.
  # `syrus_app_events_delivered_total`
  # (AppEvents) and `syrus_detail_snapshot_requests_total{outcome:computed}`
  # (App::JobWorkflowsSnapshotCache) are both cluster counters -- cumulative
  # totals since boot, not per-interval counts -- so this sampler cannot
  # divide their raw values directly; instead it snapshots both totals every
  # tick and divides the *deltas* since the previous tick, the same
  # cursor-over-a-cumulative-total shape Metrics::LandingSampler uses for its
  # counters, just one tick shallower because both sources are already
  # cluster-aggregated (Metrics::ClusterCounters.totals) rather than raw rows
  # this sampler would otherwise have to cursor over itself.
  #
  # The first tick ever (no previous snapshot cached) only records a
  # baseline and reports no ratio -- there is no trailing-window delta yet,
  # and dividing by the all-time-since-boot total would read as a ratio for
  # a window that never happened. Same instinct as Metrics::ProductUsage's
  # zero-preset and Metrics::LandingSampler's cursor bootstrap.
  class AmplificationSampler
    CACHE_KEY = "syrus:metrics:amplification_sample".freeze
    PREVIOUS_TOTALS_CACHE_KEY = "syrus:metrics:amplification_sample:totals".freeze
    # Same reasoning as the other samplers' CACHE_TTL: longer than the
    # sampling period so one missed tick does not blank the dashboard.
    CACHE_TTL = 5.minutes
    # Must outlive a single missed tick (or the ratio cache expiring)
    # without losing the previous snapshot -- losing it would silently
    # re-bootstrap and report "no ratio yet" instead of a real one.
    PREVIOUS_TOTALS_TTL = 1.day

    EVENTS_METRIC = "syrus_app_events_delivered_total".freeze
    REQUESTS_METRIC = "syrus_detail_snapshot_requests_total".freeze

    def self.declare_metrics!
      Syrus::Metrics.declare do
        gauge :event_amplification_ratio, tags: %i[resource],
              comment: "Detail-snapshot requests actually computed per application event delivered, over the " \
                       "trailing sampling window, by resource (GLOBAL -- aggregate with max by, never sum) -- " \
                       "rising means events are causing more backend work per event. Omitted for a " \
                       "resource with no events in the window, or before the first full sampling window."
      end
    end
    declare_metrics!
    Syrus::Metrics.register_sampler(self)

    def self.sample!(...) = new.sample!
    def self.refresh_gauges!(...) = new.refresh_gauges!

    # Runs on the recurring schedule (SampleGlobalMetricsJob). Writes the
    # sample to the cache; does not touch the gauges -- see
    # Metrics::QueueSampler for why.
    def sample!
      events_now = totals_for(EVENTS_METRIC)
      requests_now = computed_totals_for(REQUESTS_METRIC)
      previous = Rails.cache.read(PREVIOUS_TOTALS_CACHE_KEY)

      ratios = previous ? ratios_from(events_now, requests_now, previous) : {}

      Rails.cache.write(PREVIOUS_TOTALS_CACHE_KEY, { "events" => events_now, "requests" => requests_now }, expires_in: PREVIOUS_TOTALS_TTL)
      Rails.cache.write(CACHE_KEY, ratios, expires_in: CACHE_TTL)
      ratios
    end

    # Called on the scrape path. Reads the cached sample -- one indexed key
    # lookup, not an aggregate query. A dead sampler (expired cache, never
    # ticked) must not leave a stale prior ratio rendering forever -- that
    # reads as "still healthy" through the exact outage this gauge exists to
    # surface -- so every resource this gauge currently knows about that the
    # fresh sample no longer mentions gets cleared, not merely left alone.
    def refresh_gauges!
      ratios = Rails.cache.read(CACHE_KEY)
      gauge = Syrus::Metrics.gauge(:syrus_event_amplification_ratio)
      known_resources = gauge.samples.map { |labels, _value| labels[:resource] }.uniq

      if ratios.nil?
        known_resources.each { |resource| gauge.clear(tags: { resource: resource }) }
        return false
      end

      (known_resources - ratios.keys).each { |resource| gauge.clear(tags: { resource: resource }) }
      ratios.each do |resource, ratio|
        ratio.nil? ? gauge.clear(tags: { resource: resource }) : gauge.set(ratio, tags: { resource: resource })
      end
      true
    end

    private

    def ratios_from(events_now, requests_now, previous)
      resources = events_now.keys | requests_now.keys | previous["events"].keys | previous["requests"].keys
      resources.index_with do |resource|
        event_delta = delta(events_now[resource], previous["events"][resource])
        request_delta = delta(requests_now[resource], previous["requests"][resource])
        event_delta.positive? ? (request_delta.to_f / event_delta) : nil
      end
    end

    # Clamped at 0: a cluster counter's persisted total should only ever grow,
    # but a negative delta from an unexpected reset must read as "nothing
    # happened" rather than produce a nonsensical negative ratio.
    def delta(current, previous)
      [ (current || 0) - (previous || 0), 0 ].max
    end

    def totals_for(metric_name)
      Metrics::ClusterCounters.totals.fetch(metric_name, []).each_with_object(Hash.new(0)) do |(labels, value), out|
        out[labels[:resource].to_s] += value
      end
    end

    def computed_totals_for(metric_name)
      Metrics::ClusterCounters.totals.fetch(metric_name, []).each_with_object(Hash.new(0)) do |(labels, value), out|
        next unless labels[:outcome].to_s == "computed"

        out[labels[:resource].to_s] += value
      end
    end
  end
end
