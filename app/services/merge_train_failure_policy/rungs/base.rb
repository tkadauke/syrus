class MergeTrainFailurePolicy
  module Rungs
    class Base
      def self.name = raise NotImplementedError

      def preserve_train?(retryable_failure:)
        false
      end

      def keep_fixes?
        false
      end
    end
  end
end
