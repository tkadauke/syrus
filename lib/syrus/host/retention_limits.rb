module Syrus
  module Host
    # Default limits for retention executors.
    module RetentionLimits
      def self.default_batch_size = ::RetentionPruner::DEFAULT_BATCH_SIZE
      def self.default_max_batches = ::RetentionPruner::DEFAULT_MAX_BATCHES
    end
  end
end
