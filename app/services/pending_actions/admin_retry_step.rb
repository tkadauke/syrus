module PendingActions
  class AdminRetryStep < Base
    action_key "admin_retry_step"

    def execute
      workflow = Workflow.find(payload.fetch("workflow_id"))
      step_slug = payload.fetch("step_slug").to_s
      failed_step = RetryFailedStepEnqueuer.failed_step_for(workflow)
      unless failed_step&.kind == step_slug
        raise ArgumentError, "Step '#{step_slug}' is not the retryable failed step on #{workflow.slug}."
      end

      progress!("Retrying #{step_slug} in #{workflow.slug}...")
      mode = RetryJobs::Modes::FailedStep.new(job: workflow.job, source_workflow_id: workflow.id)
      result = RecoveryInterventions::Perform.call(
        job: workflow.job, source_workflow: workflow, action: mode.recovery_action, mode: "failed_step",
        actor_type: action.requested_by.presence || "unknown", actor: user,
        origin: "mcp_admin_retry_step", reason:
      ) { mode.execute }
      raise ArgumentError, result.error unless result.success?

      result.run
    end

    def execution_label
      "Retrying failed step..."
    end

    def validate_payload(errors)
      errors.add(:payload, "workflow_id is required") unless payload["workflow_id"].present?
      errors.add(:payload, "step_slug is required") if payload["step_slug"].to_s.strip.blank?
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "workflow_id: #{payload["workflow_id"]}, step_slug: #{payload["step_slug"]}"
    end

    def presentation_label
      "Retry step #{payload["step_slug"]} on workflow ##{payload["workflow_id"]}"
    end

    def repair_action?
      true
    end

    def repair_snapshot_targets
      workflow = Workflow.find_by(id: payload["workflow_id"])
      [ workflow&.job ]
    end
  end
end
