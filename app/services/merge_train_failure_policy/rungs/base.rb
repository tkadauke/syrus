class MergeTrainFailurePolicy
  module Rungs
    class Base
      def self.name = raise NotImplementedError

      def preserve_train?(retryable_failure:, rebuild_required: false)
        false
      end
    end
  end
end
