module Achievements
  module Evaluators
    # Earned once the installation has landed THRESHOLD operator Jobs. The count
    # is recomputed from current state rather than incremented, so duplicate or
    # out-of-order events cannot skew it.
    class Threshold < Base
      THRESHOLD = 5

      private

      def earned?(_definition, adapter)
        return false unless adapter.subject.kind == :job

        ::Job.where(closure_reason: EventAdapters::JobClosed::LANDED_REASONS).count >= THRESHOLD
      end
    end
  end
end
