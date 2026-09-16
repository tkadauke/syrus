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

      # Removes a series entirely rather than setting it to some value --
      # for a condition that is sometimes not applicable at all (e.g. "no
      # landings in the window, so there is no ratio"), `set`ting anything,
      # including 0, would misread as a real observation. Once a key is
      # cleared it stays absent from #samples (and therefore from a render)
      # until #set is called again, so a sampler can flip a gauge between
      # "reporting" and "genuinely has nothing to report" tick to tick.
      def clear(tags: {})
        key = key_for(tags)
        @mutex.synchronize { @values.delete(key) }
      end
    end
  end
end
