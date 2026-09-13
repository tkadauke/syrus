module Syrus
  module Metrics
    # Bucketed observations. Each bucket is a *counter* of observations less
    # than or equal to its boundary, which is precisely why histograms aggregate
    # across processes where summaries do not: counters sum, quantiles do not.
    #
    # The cost is that a quantile read back out is an interpolation bounded by
    # bucket width, so buckets must be placed where the resolution is actually
    # needed rather than left at a library default.
    class Histogram < Instrument
      attr_reader :buckets

      def initialize(definition)
        super
        @buckets = definition.buckets.map(&:to_f).sort.freeze
      end

      def observe(value, tags: {})
        value = value.to_f
        key = key_for(tags)
        @mutex.synchronize do
          entry = (@values[key] ||= { buckets: Hash.new(0), sum: 0.0, count: 0 })
          @buckets.each { |bound| entry[:buckets][bound] += 1 if value <= bound }
          entry[:sum] += value
          entry[:count] += 1
        end
      end

      # Times the block and records how long it took, returning whatever the
      # block returned. Failures are still observed -- an operation that blew up
      # after 30 seconds took 30 seconds, and omitting it would flatter the
      # distribution exactly when it matters.
      def measure(tags: {})
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
      ensure
        observe(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, tags: tags)
      end
    end
  end
end
