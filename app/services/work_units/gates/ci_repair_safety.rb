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

        if launch_gate_step?
          return block("base_sha_unknown") if base_sha.blank?
          return block("branch_behind_base", "commits_behind_base" => job.commits_behind_base) if job.commits_behind_base.to_i.positive?
        elsif !ci_failure_retry_loop_step?
          return GateResult.pass
        end

        return block("base_sha_unknown") if base_sha.blank?

        if require_clean_base_health? && !clean_base_health_known?
          return block("base_repair_active", active_base_repair_details) if active_base_repair?

          return block("base_not_known_healthy", "base_sha" => base_sha)
        end

        if launch_gate_step? && (duplicate = active_duplicate_for_base)
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

        return true if repository.last_health_checked_sha == base_sha &&
          repository.last_ci_evaluated_sha == base_sha &&
          repository.last_graded_sha == base_sha &&
          repository.ci_health == "healthy" &&
          repository.grader_health == "healthy"

        MainBranchHealthCheck
          .where(repository: repository, sha: base_sha)
          .where(ci_health: %w[healthy not_configured], grader_health: "healthy")
          .exists?
      end

      def require_clean_base_health?
        job.repository&.main_branch_health_enabled?
      end

      def launch_gate_step?
        return true unless step

        first_step = workflow.first_step
        first_step.blank? || step.id == first_step.id
      end

      def ci_failure_retry_loop_step?
        return false unless step&.loop_id.present?
        return false unless %w[ analyze_and_fix grader_fanout grader_collect grader ].include?(step.kind)

        loop_node = retry_loop_node_for(step)
        loop_node.present?
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

      def active_base_repair?
        active_base_repair_workflow.present?
      end

      def active_base_repair_details
        repair = active_base_repair_workflow
        {
          "base_sha" => base_sha,
          "repair_workflow_id" => repair&.id,
          "repair_job_id" => repair&.job_id,
          "repair_trigger_kind" => repair&.trigger_kind
        }.compact
      end

      def active_base_repair_workflow
        @active_base_repair_workflow ||= active_main_branch_repair_workflow || active_ci_repair_on_main_workflow
      end

      def active_main_branch_repair_workflow
        active_repair_workflows(%w[ main_branch_repair ]).find do |candidate|
          repair_target_sha(candidate.job) == base_sha
        end
      end

      def active_ci_repair_on_main_workflow
        active_repair_workflows(%w[ ci_failure ]).find do |candidate|
          candidate.job&.main_branch_repair? && repair_target_sha(candidate.job) == base_sha
        end
      end

      def active_repair_workflows(trigger_kinds)
        Workflow
          .joins(:job)
          .where(
            state: Workflow::TriggerKind::ACTIVE_STATES,
            trigger_kind: trigger_kinds,
            jobs: { repository_id: job.repository_id }
          )
          .where.not(id: workflow.id)
          .includes(:job)
          .to_a
      end

      def repair_target_sha(candidate_job)
        candidate_job&.issue_body.to_s[/^Commit:\s*([0-9a-f]{7,40})\b/i, 1]
      end

      def retry_loop_node_for(candidate_step)
        workflow_template_nodes.find do |node|
          next false unless node["type"] == "retry_until"
          next false unless retry_loop_step_kinds(node).include?("analyze_and_fix")

          retry_loop_step_kinds(node).include?(candidate_step.kind) ||
            runtime_grader_step_for_retry_loop?(candidate_step, node)
        end
      end

      def retry_loop_step_kinds(node)
        Array(node["repair"]).map(&:to_s) + Array(node["check"]).map(&:to_s)
      end

      def runtime_grader_step_for_retry_loop?(candidate_step, node)
        candidate_step.kind == "grader" && Array(node["check"]).map(&:to_s).include?("grader_fanout")
      end

      def workflow_template_nodes
        Array(workflow.chain_template).flat_map { |node| flatten_template_node(node) }
      end

      def flatten_template_node(node)
        return [] unless node.is_a?(Hash)

        if node["type"] == "try"
          [ node ] + node.fetch("on_failure", {}).values.flat_map { |nodes| Array(nodes).flat_map { |child| flatten_template_node(child) } }
        else
          [ node ]
        end
      end

      def block(kind, details = {})
        details = details.merge(phase_step_details)
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

      def phase_step_details
        return {} unless step

        {
          "phase_step_id" => step.id,
          "phase_step_kind" => step.kind,
          "phase_step_position" => step.position
        }
      end
    end
  end
end
