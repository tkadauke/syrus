module WorkIntents
  module Gates
    class EpicReadiness
      REASON = "epic_not_ready"
      READY_STATES = %w[approved landing closed].freeze

      def self.call(intent) = new(intent).call

      def initialize(intent)
        @intent = intent
      end

      def call
        return GateResult.pass unless intent.definition.requires_epic_readiness?
        return GateResult.pass unless intent.scope_type == "epic" && intent.scope_id.present?

        waiting_jobs = Job
          .where(epic_id: intent.scope_id)
          .where.not(state: READY_STATES)
          .order(:id)
          .to_a
        return GateResult.pass if waiting_jobs.empty?

        GateResult.wait(
          reason: REASON,
          details: {
            "epic_id" => intent.scope_id,
            "waiting_job_ids" => waiting_jobs.map(&:id),
            "waiting_job_slugs" => waiting_jobs.map(&:slug),
            "states" => waiting_jobs.index_by(&:id).transform_values(&:state)
          }
        )
      end

      private

      attr_reader :intent
    end
  end
end
