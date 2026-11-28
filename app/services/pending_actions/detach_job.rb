module PendingActions
  class DetachJob < Base
    action_key "detach_job"
    admin_only!
    repairs_job!

    def perform
      job = repair_action_job
      raise ArgumentError, "No live PR on this Job to detach." if job.pr_number.blank? || job.branch_name.blank?
      raise ArgumentError, "Terminal Jobs cannot be detached." if job.closed? || job.no_change_needed?
      raise ArgumentError, "A rebase is already in progress — wait for it to finish." if RebaseWorkflowSelector.active_for_stack?(job)
      raise ArgumentError, "A merge train is already active for this stack — wait for it to finish." if RebaseWorkflowSelector.active_merge_train_for_stack?(job)
      # Detach force-pushes the branch and moves the PR base; work holding the
      # Job (a feedback or auto-merge Workflow) would then fail on its push or
      # merge and lose its work (F146).
      if (active = job.active_runtime_workflows.first)
        raise ArgumentError, "#{job.slug} has active work (Workflow ##{active.id}, #{active.trigger_kind}); wait for it to finish or cancel it before detaching."
      end

      result = JobDetachRepair.call(
        job: job,
        destination_base: payload.fetch("destination_base"),
        reason: reason,
        requested_by: "chat_agent",
        former_parent_id: payload.dig("plan", "inferred_parent_job_id"),
        former_parent_head: payload.dig("plan", "former_parent_head"),
        owned_patch_base_sha: payload.dig("plan", "owned_patch_base_sha"),
        confirmed_head: payload.dig("plan", "current_branch_head")
      )
      action.update!(payload: payload.merge("result" => result.evidence, "status" => result.status, "workflow_id" => result.workflow&.id))
      audit!("detach repair #{result.status}; destination=#{payload.fetch('destination_base')}; workflow=#{result.workflow&.id || 'none'}", run: result.workflow&.latest_run || job.current_run)
      result.workflow
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:payload, "destination_base is required") if payload["destination_base"].blank?
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail = "job_id: #{payload['job_id']}, destination_base: #{payload['destination_base']}"
    def presentation_label = "Detach #{presentation_job_slug} to #{payload['destination_base']}"
  end
end
