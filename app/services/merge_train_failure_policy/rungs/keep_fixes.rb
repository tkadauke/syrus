class MergeTrainFailurePolicy
  module Rungs
    # Everything `keep_assembly` does, plus: once the train IS torn down, keep
    # its integration branch so the landing fixes committed during the grade
    # loop can be replayed onto the next assembly rather than rediscovered.
    #
    # Before this, KeepFixes subclassed KeepAssembly and added nothing, so a
    # ladder of [keep_fixes, keep_assembly, restart] escalated from a rung to
    # an identical rung before doing anything different on attempt three.
    class KeepFixes < KeepAssembly
      def self.name = "keep_fixes"

      def preserve_branch_for_replay?
        true
      end
    end
  end
end
