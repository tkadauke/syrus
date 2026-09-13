module Syrus
  module Metrics
    # Shared storage for the three instrument types: a hash keyed by the sorted
    # label set, guarded by a mutex.
    #
    # A mutex rather than Concurrent::Map because the critical sections are a
    # few microseconds of arithmetic and the contention story is simple to
    # reason about. If this ever shows up in a profile, the fix is per-shard
    # locks, not lock-free cleverness.
    class Instrument
      EMPTY_KEY = {}.freeze

      attr_reader :definition

      def initialize(definition)
        @definition = definition
        @mutex = Mutex.new
        @values = {}
      end

      def name = definition.name
      def type = definition.type

      # [[tags_hash, value], ...] for rendering. Copied under the lock so the
      # renderer never iterates a hash that is being mutated.
      def samples
        @mutex.synchronize { @values.map { |labels, value| [ labels, value ] } }
      end

      def empty? = @mutex.synchronize { @values.empty? }

      private

      # Declared labels only, in a stable order, so the same logical series
      # always produces the same key. An undeclared label is dropped rather
      # than raising: a wrong label must not take down the call site, and the
      # declaration is what the catalog and the allowlist guard read anyway.
      def key_for(tags)
        return EMPTY_KEY if definition.tags.empty?

        definition.tags.to_h { |tag| [ tag, (tags[tag] || tags[tag.to_s])&.to_s ] }.freeze
      end
    end
  end
end
