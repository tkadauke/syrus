module RetryJobs
  module Modes
    class Auto < Mode
      def preflight = retry_preflight
      def execute = RetryWorkflowEnqueuer.call(job: job)
    end
  end
end
