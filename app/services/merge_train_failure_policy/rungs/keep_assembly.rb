class MergeTrainFailurePolicy
  module Rungs
    # Keep the assembled train and its integration branch for the next attempt
    # when the failure was not any member's fault, so the retry reuses what was
    # already built instead of paying assembly and grading again.
    class KeepAssembly < Base
      def self.name = "keep_assembly"

      def preserve_train?(preservable_failure:)
        preservable_failure
      end
    end
  end
end
