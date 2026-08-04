module PendingActions
  class ReplacePrBranchWithWorkflowOutput < Base
    action_key "replace_pr_branch_with_workflow_output"

    def execute
      raise ArgumentError, "Admin access required." unless user.admin?

      job = repair_action_job
      workflow = divergence_workflow(job)
      raise ArgumentError, "destructive confirmation is required" unless destructive_confirmation_valid?

      result = BranchDivergenceRecovery.mark_force_push_pending!(workflow: workflow, user: user)
      raise ArgumentError, result.error unless result.success?

      BranchDivergenceRecoveryJob.perform_later(workflow.id, user.id)
      audit!(job, workflow)
      workflow
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:payload, "workflow_id is required") unless payload["workflow_id"].present?
      errors.add(:payload, "destructive_confirmation must be REPLACE PR BRANCH") unless destructive_confirmation_valid?
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "job_id: #{payload["job_id"]}, workflow_id: #{payload["workflow_id"]}, destructive_confirmation: #{payload["destructive_confirmation"].present?}"
    end

    def repair_action? = true
    def repair_snapshot_targets = [ repair_action_job_or_nil ]

    private

    def divergence_workflow(job)
      workflow = job.workflows.find(payload.fetch("workflow_id"))
      raise ArgumentError, "Workflow has no recorded branch divergence." unless workflow.artifact("branch_divergence").present?

      workflow
    end

    def destructive_confirmation_valid?
      payload["destructive_confirmation"].to_s == "REPLACE PR BRANCH"
    end

    def audit!(job, workflow)
      run = job.current_run || workflow.runs.order(:created_at).last
      return unless run

      JobLog.append!(
        run: run,
        chunk: "[operator repair] queued PR branch replacement from #{workflow.slug}; reason=#{reason}",
        kind: "system"
      )
    end
  end
end
