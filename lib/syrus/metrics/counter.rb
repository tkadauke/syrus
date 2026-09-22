module Syrus
  module Metrics
    # Monotonic and cumulative. There is no `set`, no `decrement` and no reset:
    # a counter only ever goes up, and the one legitimate reset (process
    # restart, where the series returns to zero) is detected and compensated for
    # by PromQL's rate()/increase().
    #
    # This is what removes the entire "reset the interval counter at exactly the
    # right moment" problem: the interval is chosen by whoever asks the
    # question, at read time, rather than baked in at write time.
    class Counter < Instrument
      def increment(by: 1, tags: {})
        raise ArgumentError, "counters only increase (got by: #{by})" if by.negative?

        key = key_for(tags)
        @mutex.synchronize { @values[key] = (@values[key] || 0) + by }
        record_cluster_increment(key, by) if definition.cluster
      end

      # Declares a series at zero without incrementing it. This is what makes
      # "nobody uses this feature" visible: an absent series and a zero series
      # look identical on a dashboard unless the zero is published.
      def preset(tags: {})
        key = key_for(tags)
        @mutex.synchronize { @values[key] ||= 0 }
      end

      # Overwrites the tracked value for one tag combination to an externally
      # computed absolute total, for a counter whose true source of truth is a
      # periodic aggregate sample cached outside this process rather than an
      # event this process witnessed directly (see Metrics::LandingSampler,
      # which counts events -- like a Run finishing -- that happen on a
      # worker process but must still render from the web process that serves
      # /metrics). Idempotent: calling this repeatedly with the same total is
      # a no-op, and the monotonic invariant still holds because the tracked
      # value never moves backward -- a stale or reset upstream total simply
      # does not apply rather than making the series appear to shrink.
      #
      # Compared and stored as floats (not `.to_i`) so a fractional cumulative
      # total -- e.g. summed dollar cost -- is not silently floored to the
      # nearest whole unit on every tick.
      def reconcile!(total, tags: {})
        key = key_for(tags)
        @mutex.synchronize { @values[key] = total if total.to_f > (@values[key] || 0).to_f }
      end

      private

      # Hands the increment to the cluster sink as well. Instrumentation must
      # never raise or block, so the sink only buffers, and any failure is
      # swallowed here.
      def record_cluster_increment(key, by)
        Syrus::Metrics.cluster_sink&.record(name, key, by)
      rescue StandardError => e
        Rails.logger&.warn("[Syrus::Metrics] cluster counter #{name}: #{e.class}: #{e.message}") if defined?(Rails)
      end
    end
  end
end
