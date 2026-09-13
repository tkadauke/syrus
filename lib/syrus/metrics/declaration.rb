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

      attr_reader :definitions

      def initialize(owner:, prefix: nil)
        @owner = owner
        @plugin_prefix = prefix
        @definitions = []
      end

      def counter(name, tags: [], comment: nil, share: false)
        add(name, :counter, tags: tags, comment: comment, share: share)
      end

      def gauge(name, tags: [], comment: nil, share: false)
        add(name, :gauge, tags: tags, comment: comment, share: share)
      end

      def histogram(name, buckets:, tags: [], comment: nil, share: false)
        add(name, :histogram, tags: tags, comment: comment, share: share, buckets: buckets)
      end

      private

      def add(name, type, tags:, comment:, share:, buckets: nil)
        @definitions << Definition.new(
          name: :"#{PREFIX}#{@plugin_prefix}#{name}",
          type: type,
          tags: Array(tags).map(&:to_sym),
          comment: comment,
          owner: @owner,
          share: share,
          buckets: buckets
        )
      end
    end
  end
end
