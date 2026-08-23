module WorkIntents
  module Gates
    class Approval
      REASON = "approval"
      READY_STATES = %w[approved landing].freeze

      def self.call(intent) = new(intent).call

      def initialize(intent)
        @intent = intent
      end

      def call
        return GateResult.pass unless intent.definition.requires_approval?

        jobs = jobs_requiring_approval
        return GateResult.pass if jobs.empty?

        waiting_jobs = jobs.reject { |job| READY_STATES.include?(job.state) }
        return GateResult.pass if waiting_jobs.empty?

        GateResult.wait(
          reason: REASON,
          details: {
            "waiting_job_ids" => waiting_jobs.map(&:id),
            "waiting_job_slugs" => waiting_jobs.map(&:slug),
            "states" => waiting_jobs.index_by(&:id).transform_values(&:state)
          }
        )
      end

      private

      attr_reader :intent

      def jobs_requiring_approval
        case intent.scope_type
        when "job"
          Job.where(id: intent.scope_id).to_a
        when "epic"
          Job.where(epic_id: intent.scope_id).where.not(state: "closed").to_a
        else
          []
        end
      end
    end
  end
end
