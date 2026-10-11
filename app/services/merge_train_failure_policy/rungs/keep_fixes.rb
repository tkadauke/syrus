class MergeTrainFailurePolicy
  module Rungs
    class KeepFixes < KeepAssembly
      def self.name = "keep_fixes"

      def keep_fixes?
        true
      end
    end
  end
end
