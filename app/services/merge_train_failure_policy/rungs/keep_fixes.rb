class MergeTrainFailurePolicy
  module Rungs
    class KeepFixes < Base
      def self.name = "keep_fixes"

      def preserve_train?(retryable_failure:, rebuild_required: false)
        retryable_failure && !rebuild_required
      end
    end
  end
end
