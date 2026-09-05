module PendingActions
  class AdoptCurrentPrHead < Base
    action_key "adopt_current_pr_head"

    def perform
      job = repair_action_job
      workflow = divergence_workflow(job)
      progress!("Adopting current PR head for #{workflow.slug}...")
      result = BranchDivergenceRecovery.adopt_current_pr_head!(workflow: workflow, user: user)
      raise ArgumentError, result.error unless result.success?

      progress!("Recording repair audit...")
      audit!("adopted current PR head for #{workflow.slug}", run: job.current_run || workflow.runs.order(:created_at).last)
      workflow
    end

    def execution_label
      "Adopting current PR head..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:payload, "workflow_id is required") unless payload["workflow_id"].present?
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "job_id: #{payload["job_id"]}, workflow_id: #{payload["workflow_id"]}"
    end

    repairs_job!

    private

    def divergence_workflow(job)
      workflow = job.workflows.find(payload.fetch("workflow_id"))
      raise ArgumentError, "Workflow has no recorded branch divergence." unless workflow.artifact("branch_divergence").present?

      workflow
    end
  end
end
