class MergeTrainFailurePolicy
  module Rungs
    class KeepAssembly < Base
      def self.name = "keep_assembly"

      def preserve_train?(retryable_failure:)
        retryable_failure
      end
    end
  end
end
