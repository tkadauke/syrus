module WorkUnits
  module Gates
    class CiRepairSafety
      REASON = "ci_repair_safety"
      RETRY_DELAY = 5.minutes

      def self.call(work_unit, **context) = new(work_unit, step: context[:step]).call

      def initialize(work_unit, step: nil)
        @work_unit = work_unit
        @step = step
      end

      def call
        return GateResult.pass unless work_unit.kind == "ci_failure"
        return GateResult.pass unless workflow
        return GateResult.pass unless job
        return GateResult.pass if job.main_branch_repair?
        return GateResult.pass if resumed_past_launch_gate?

        return block("base_sha_unknown") if base_sha.blank?
        return block("branch_behind_base", "commits_behind_base" => job.commits_behind_base) if job.commits_behind_base.to_i.positive?
        return block("base_not_known_healthy", "base_sha" => base_sha) if require_clean_base_health? && !clean_base_health_known?

        if (duplicate = active_duplicate_for_base)
          return block(
            "duplicate_active_ci_repair",
            "base_sha" => base_sha,
            "duplicate_workflow_id" => duplicate.id,
            "duplicate_job_id" => duplicate.job_id
          )
        end

        GateResult.pass
      end

      private

      attr_reader :work_unit, :step

      def workflow
        @workflow ||= work_unit.workflow
      end

      def job
        @job ||= begin
          primary = work_unit.work_unit_members.includes(:job).find { |member| member.role == "primary" }&.job
          primary || workflow&.job || (Job.find_by(id: work_unit.scope_id) if work_unit.scope_type == "job")
        end
      end

      def base_sha
        @base_sha ||= artifact("base_sha")
      end

      def artifact(key)
        workflow&.artifact(key).presence || work_unit.work_intent&.payload_artifacts.to_h[key].presence
      end

      def clean_base_health_known?
        repository = job.repository
        return false unless repository

        repository.last_health_checked_sha == base_sha &&
          repository.last_ci_evaluated_sha == base_sha &&
          repository.last_graded_sha == base_sha &&
          repository.ci_health == "healthy" &&
          repository.grader_health == "healthy"
      end

      def require_clean_base_health?
        job.repository&.main_branch_health_enabled?
      end

      def resumed_past_launch_gate?
        return false unless step

        first_step = workflow.first_step
        first_step && step.id != first_step.id
      end

      def active_duplicate_for_base
        active_ci_repair_workflows.find do |candidate|
          next false if candidate.id == workflow.id

          candidate_base_sha(candidate) == base_sha
        end
      end

      def active_ci_repair_workflows
        workflow_ids = WorkUnit
          .where(
            repository_id: job.repository_id,
            kind: "ci_failure",
            state: WorkUnits::Ownership::ACTIVE_STATES
          )
          .where.not(id: work_unit.id)
          .where.not(workflow_id: nil)
          .distinct
          .pluck(:workflow_id)

        return [] if workflow_ids.empty?

        Workflow.where(id: workflow_ids).includes(:job, work_unit: :work_intent).to_a
      end

      def candidate_base_sha(candidate)
        candidate.artifact("base_sha").presence || candidate.work_unit&.work_intent&.payload_artifacts.to_h["base_sha"].presence
      end

      def block(kind, details = {})
        GateResult.block(
          reason: REASON,
          retry_at: RETRY_DELAY.from_now,
          details: {
            "kind" => kind,
            "job_id" => job.id,
            "repository_id" => job.repository_id
          }.merge(details)
        )
      end
    end
  end
end
