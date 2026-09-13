module Syrus
  module Metrics
    # A value that goes up and down and is sampled rather than accumulated:
    # queue depth, CPU percent, jobs in flight. The "absolute value" case.
    class Gauge < Instrument
      def set(value, tags: {})
        key = key_for(tags)
        @mutex.synchronize { @values[key] = value }
      end

      def increment(by: 1, tags: {})
        key = key_for(tags)
        @mutex.synchronize { @values[key] = (@values[key] || 0) + by }
      end

      def decrement(by: 1, tags: {}) = increment(by: -by, tags: tags)
    end
  end
end
