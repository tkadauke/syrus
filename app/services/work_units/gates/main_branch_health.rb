module WorkUnits
  module Gates
    class MainBranchHealth
      REASON = "main_branch_health"

      def self.call(work_unit, **) = new(work_unit).call

      def initialize(work_unit)
        @work_unit = work_unit
      end

      def call
        return GateResult.pass unless workflow
        return GateResult.pass unless StepDispatcher.main_health_blocking?(workflow)

        GateResult.block(
          reason: REASON,
          retry_at: StepDispatcher::START_BLOCKED_BACKOFF.from_now,
          details: {
            "repository_id" => workflow.job.repository_id,
            "repository_slug" => workflow.job.repository.slug,
            "main_health_state" => "broken"
          }
        )
      end

      private

      attr_reader :work_unit

      def workflow
        work_unit.workflow
      end
    end
  end
end
