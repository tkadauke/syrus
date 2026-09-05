module PendingActions
  class RetryFromCurrentPrBranch < Base
    action_key "retry_from_current_pr_branch"

    DEFAULT_INSTRUCTIONS = "Start from the current remote PR branch, inspect the recorded branch divergence, and repair only the remaining work needed for this Job. Do not replay stale workflow output unless it is still required.".freeze

    def perform
      job = repair_action_job
      progress!("Validating branch divergence for #{job.slug}...")
      divergence_workflow(job)
      progress!("Creating retry workflow from current PR branch...")
      result = ::ManualAgenticRun::Enqueuer.call(
        job: job,
        base: "current_pr_branch",
        instructions: instructions,
        reason: reason,
        push: true
      )
      progress!("Recording repair audit...")
      audit!(
        "started retry_from_current_pr_branch workflow ##{result.workflow.id}; source_workflow_id=#{payload["workflow_id"]}; instructions=#{instructions}",
        run: result.run
      )
      result.workflow
    end

    def execution_label
      "Starting retry from current PR branch..."
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

    def instructions
      payload["instructions"].to_s.strip.presence || DEFAULT_INSTRUCTIONS
    end
  end
end
