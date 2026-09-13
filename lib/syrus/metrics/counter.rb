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
      end

      # Declares a series at zero without incrementing it. This is what makes
      # "nobody uses this feature" visible: an absent series and a zero series
      # look identical on a dashboard unless the zero is published.
      def preset(tags: {})
        key = key_for(tags)
        @mutex.synchronize { @values[key] ||= 0 }
      end
    end
  end
end
