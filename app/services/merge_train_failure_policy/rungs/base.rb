class MergeTrainFailurePolicy
  module Rungs
    # A rung answers two independent questions about one failed train attempt:
    # whether to keep the assembly for the next attempt, and whether to keep
    # the integration branch around afterwards so a repair can be replayed onto
    # it. Keeping them separate is what distinguishes `keep_fixes` from
    # `keep_assembly` -- while both answered only the first question they were
    # the same rung under two names, and a ladder that listed both escalated
    # through a duplicate.
    class Base
      def self.name = raise NotImplementedError

      # `preservable_failure` is "this failure is not attributable to a
      # member's own code" -- see MergeTrainFailureHandler#preservable_failure?.
      def preserve_train?(preservable_failure:)
        false
      end

      def preserve_branch_for_replay?
        false
      end
    end
  end
end
