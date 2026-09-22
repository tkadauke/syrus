module Syrus
  module Metrics
    # The DSL body of a `declare` block. Collects definitions; the registry does
    # the validating and the registering.
    #
    #   counter :runs_total, tags: %i[state], comment: "..."
    #   gauge   :queue_ready, tags: %i[queue], comment: "..."
    #   histogram :run_duration_seconds, buckets: [1, 5, 60], comment: "..."
    #
    # Every metric is emitted as `syrus_<name>`, and a plugin's as
    # `syrus_<plugin>_<name>`. The prefix is applied here rather than written by
    # the declaring author, so a plugin cannot declare into core's namespace.
    class Declaration
      PREFIX = "syrus_".freeze

      attr_reader :definitions, :samplers

      def initialize(owner:, prefix: nil)
        @owner = owner
        @plugin_prefix = prefix
        @definitions = []
        @samplers = []
      end

      # `cluster: true` makes the counter count across processes: every
      # process's increments are summed into one cluster-wide total (see
      # Metrics::ClusterCounters) that web renders on /metrics. Use it for
      # counters incremented on workers, which are otherwise invisible -- the
      # forked Solid Queue processes share no memory and are not scraped.
      def counter(name, tags: [], comment: nil, share: false, cluster: false)
        add(name, :counter, tags: tags, comment: comment, share: share, cluster: cluster)
      end

      # A block turns this into a *sampled* gauge: the framework calls it on
      # the shared control-plane tick (Syrus::Metrics.samplers, driven by
      # SampleGlobalMetricsJob), caches the result, and sets the live gauge
      # from that cache on every /metrics scrape -- no tick_interval, on_tick,
      # or hand-written sampler class needed for the common case of "read one
      # aggregate value on a timer". Untagged only, since the block returns a
      # single scalar; for several gauges off one query pass, or a counter/
      # histogram that needs cursor-based cumulative logic, declare a full
      # sampler class with `sampler` instead (see Metrics::QueueSampler).
      def gauge(name, tags: [], comment: nil, share: false, &sample_block)
        add(name, :gauge, tags: tags, comment: comment, share: share, sample_block: sample_block)
      end

      def histogram(name, buckets:, tags: [], comment: nil, share: false)
        add(name, :histogram, tags: tags, comment: comment, share: share, buckets: buckets)
      end

      # The escape hatch: klass must implement `.sample!` and
      # `.refresh_gauges!` (see Metrics::QueueSampler). Registered into the
      # same sampler registry a sampled `gauge` block uses, so
      # SampleGlobalMetricsJob and MetricsController need no plugin-specific
      # wiring either way.
      def sampler(klass)
        @samplers << klass
      end

      private

      def add(name, type, tags:, comment:, share:, buckets: nil, sample_block: nil, cluster: false)
        @definitions << Definition.new(
          name: :"#{PREFIX}#{@plugin_prefix}#{name}",
          type: type,
          tags: Array(tags).map(&:to_sym),
          comment: comment,
          owner: @owner,
          share: share,
          buckets: buckets,
          sample_block: sample_block,
          cluster: cluster
        )
      end
    end
  end
end
