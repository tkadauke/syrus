module WorkIntents
  module Gates
    # Blocks admission of new automatic work for a scope where any covered
    # Job has tripped runaway protection (Job#runaway_protection). The flag
    # itself only records that a Job stopped auto-retrying its own failed
    # Workflows -- nothing previously consulted it before launching the NEXT
    # WorkIntent for that Job's scope, so an epic-scoped intent (a merge
    # train, a job bundle) kept relaunching on its own schedule long after
    # the member Job it was landing had already been flagged as runaway,
    # spending hours re-running a landing attempt no operator had approved
    # continuing. This gate is the missing consultation: it does not set or
    # clear the flag, it only refuses admission while it is present. A
    # manual retry (RetryWorkflowEnqueuer) clears the flag before launching,
    # so the operator's own "Retry" action is never blocked by this gate.
    class RunawayProtection
      REASON = "runaway_protection_active"

      def self.call(intent) = new(intent).call

      def initialize(intent)
        @intent = intent
      end

      def call
        protected_jobs = jobs.select(&:runaway_protected?)
        return GateResult.pass if protected_jobs.empty?

        GateResult.wait(
          reason: REASON,
          details: {
            "protected_job_ids" => protected_jobs.map(&:id),
            "protected_job_slugs" => protected_jobs.map(&:slug),
            "runaway_protection" => protected_jobs.index_by(&:id).transform_values(&:runaway_protection)
          }
        )
      end

      private

      attr_reader :intent

      def jobs
        WorkIntentScope.for(intent.scope_type).jobs_requiring_approval(intent.scope_id)
      end
    end
  end
end
