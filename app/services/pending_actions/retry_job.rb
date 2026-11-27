module PendingActions
  class RetryJob < Base
    action_key "retry_job"

    def execute
      job = action_job
      mode_name = payload.fetch("mode", "auto")
      mode_arguments = { job: job, source_workflow_id: payload["source_workflow_id"], reason: payload["reason"] }
      mode_arguments[:explicit_operator_intent] = true if mode_name == "implementation"
      mode_arguments[:retry_context] = payload["context"] if payload["context"].present? && %w[failed_step implementation].include?(mode_name)
      mode = RetryJobs::Mode.for(mode_name).new(**mode_arguments)
      if mode_name == "implementation"
        preflight = mode.preflight
        raise ArgumentError, preflight.message unless preflight.eligible?
      end

      progress!("Creating #{payload.fetch('mode', 'auto').humanize(capitalize: false)} retry for #{job.slug}...")
      source_workflow = job.workflows.find_by(id: payload["source_workflow_id"])
      result = RecoveryInterventions::Perform.call(
        job:, source_workflow:, action: mode.recovery_action, mode: mode_name,
        actor_type: "operator", actor: user, origin: "mcp_retry_job",
        reason: payload["reason"].presence || action.reason, guidance: payload["context"]
      ) { mode.execute }
      raise ArgumentError, result.error unless result.success?

      result.workflow
    end

    def execution_label
      "Creating retry workflow..."
    end

    def group_confirmation_strategy
      RetryJobs::Mode.for(payload.fetch("mode", "auto")).new(job: action_job).group_confirmation_strategy
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      mode = payload.fetch("mode", "auto")
      RetryJobs::Mode.for(mode)
      errors.add(:payload, "reason is required for refresh_base") if mode == "refresh_base" && payload["reason"].blank?
    rescue ArgumentError => e
      errors.add(:payload, e.message)
    end

    def action_detail
      "job_id: #{payload["job_id"]}, mode: #{payload.fetch('mode', 'auto')}"
    end

    def presentation_label
      label = "Retry #{presentation_job_slug} (#{payload.fetch('mode', 'auto').humanize})"
      details = payload["preflight"].to_h
      if details["checkpoint_sha"].present?
        "#{label}: checkpoint #{details['checkpoint_sha'].to_s.first(12)} onto #{details['base_ref']}"
      elsif details["failed_step_kind"].present?
        "#{label}: #{details['failed_step_kind']} in workflow #{details['source_workflow_id']}"
      elsif details["base_ref"].present?
        "#{label}: from #{details['base_ref']}"
      else
        label
      end
    end

    def tool_card_review
      recovery_presentation(action)
    end

    def tool_card_outcome
      members = (action.pending_action_group&.chat_pending_actions || [ action ]).sort_by(&:id)
      workflow_ids = members.filter_map { |member| member.result_id if member.result_type == "Workflow" }
      return if workflow_ids.empty?

      job_ids_by_workflow_id = Workflow.where(id: workflow_ids).pluck(:id, :job_id).to_h
      workflows = members.filter_map do |member|
        next unless member.result_type == "Workflow"

        workflow_id = member.result_id
        job_id = job_ids_by_workflow_id[workflow_id]
        { workflow_id:, job_id:, **recovery_presentation(member) } if job_id
      end
      workflows.any? ? { workflows: workflows } : nil
    end

    private

    def recovery_presentation(member)
      member_payload = member.payload.to_h
      {
        recovery_kind: member_payload["recovery_kind"], recovery_mode: member_payload.fetch("mode", "auto"),
        recovery_action: member_payload["recovery_action"], source_workflow_id: member_payload["source_workflow_id"],
        source_failure_classification: member_payload["source_failure_classification"],
        guidance: member_payload["context"], reason: member_payload["reason"], requested_by: member.requested_by,
        origin: "mcp_retry_job"
      }.compact
    end
  end
end
