module PendingActions
  class AdoptCurrentPrHead < Base
    action_key "adopt_current_pr_head"

    def execute
      raise ArgumentError, "Admin access required." unless user.admin?

      job = repair_action_job
      workflow = divergence_workflow(job)
      result = BranchDivergenceRecovery.adopt_current_pr_head!(workflow: workflow, user: user)
      raise ArgumentError, result.error unless result.success?

      audit!(job, workflow)
      workflow
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:payload, "workflow_id is required") unless payload["workflow_id"].present?
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "job_id: #{payload["job_id"]}, workflow_id: #{payload["workflow_id"]}"
    end

    def repair_action? = true
    def repair_snapshot_targets = [ repair_action_job_or_nil ]

    private

    def divergence_workflow(job)
      workflow = job.workflows.find(payload.fetch("workflow_id"))
      raise ArgumentError, "Workflow has no recorded branch divergence." unless workflow.artifact("branch_divergence").present?

      workflow
    end

    def audit!(job, workflow)
      run = job.current_run || workflow.runs.order(:created_at).last
      return unless run

      JobLog.append!(
        run: run,
        chunk: "[operator repair] adopted current PR head for #{workflow.slug}; reason=#{reason}",
        kind: "system"
      )
    end
  end
end
