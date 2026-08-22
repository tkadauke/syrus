module WorkIntents
  module Gates
    class Dependency
      REASON = "dependency"

      def self.call(intent) = new(intent).call

      def initialize(intent)
        @intent = intent
      end

      def call
        return GateResult.pass unless job

        unsatisfied = job.unsatisfied_dependencies.to_a
        return GateResult.pass if unsatisfied.empty?

        GateResult.wait(
          reason: REASON,
          details: {
            "blocked_by_job_ids" => unsatisfied.filter_map(&:depends_on_job_id),
            "blocked_by_epic_ids" => unsatisfied.filter_map(&:depends_on_epic_id)
          }
        )
      end

      private

      attr_reader :intent

      def job
        return nil unless intent.scope_type == "job" && intent.scope_id.present?

        @job ||= Job.find_by(id: intent.scope_id)
      end
    end
  end
end
