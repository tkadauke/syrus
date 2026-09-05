module PendingActions
  class ReplacePrBranchWithWorkflowOutput < Base
    action_key "replace_pr_branch_with_workflow_output"

    def perform
      job = repair_action_job
      workflow = divergence_workflow(job)
      raise ArgumentError, "destructive confirmation is required" unless destructive_confirmation_valid?

      progress!("Marking #{workflow.slug} for PR branch replacement...")
      result = BranchDivergenceRecovery.mark_force_push_pending!(workflow: workflow, user: user)
      raise ArgumentError, result.error unless result.success?

      progress!("Queueing branch recovery job...")
      BranchDivergenceRecoveryJob.perform_later(workflow.id, user.id)
      progress!("Recording repair audit...")
      audit!("queued PR branch replacement from #{workflow.slug}", run: job.current_run || workflow.runs.order(:created_at).last)
      workflow
    end

    def execution_label
      "Queueing PR branch replacement..."
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

    repairs_job!

    private

    def divergence_workflow(job)
      workflow = job.workflows.find(payload.fetch("workflow_id"))
      raise ArgumentError, "Workflow has no recorded branch divergence." unless workflow.artifact("branch_divergence").present?

      workflow
    end

    def destructive_confirmation_valid?
      payload["destructive_confirmation"].to_s == "REPLACE PR BRANCH"
    end
  end
end
