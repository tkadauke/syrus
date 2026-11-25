module PendingActions
  class WorkflowOutcomeOverride < Base
    action_key "workflow_outcome_override"

    def perform
      job = Job.visible_to(user).find(payload.fetch("job_id"))
      decision = WorkflowOutcomeOverrides::Authority.call(user:, repository: job.repository, arguments: {
        job_id: job.id, fingerprint_digest: payload.fetch("fingerprint_digest"),
        gate_kind: payload.fetch("gate_kind"), gate_identity: payload.fetch("gate_identity")
      })
      raise Mcp::Tools::AuthorizationSupport::AuthorizationError, "permission policy denies this outcome override" if decision.deny?
      override = WorkflowOutcomeOverrides::Recorder.call(
        job:, fingerprint_digest: payload.fetch("fingerprint_digest"), actor: user,
        channel: "agent", reason: action.reason,
        permission_decision: decision.to_h.deep_stringify_keys.merge(
          "capability" => Permissions::WorkflowOutcomeOverrideActions::CAPABILITY,
          "operation" => "execute@v1", "confirmation" => "pending_action", "pending_action_id" => action.id
        )
      )
      action.update!(payload: payload.merge("workflow_outcome_override_id" => override.id))
      audit!("recorded exact-evidence workflow outcome override", run: override.step&.runs&.order(:created_at)&.last)
      nil
    end

    def validate_payload(errors)
      %w[job_id fingerprint_digest gate_kind gate_identity candidate_head_sha evidence_digest diagnosis remediation_attempted consequence].each do |key|
        errors.add(:payload, "#{key} is required") if payload[key].blank?
      end
      errors.add(:reason, "is required") if action.reason.blank?
    end

    def presentation_label = "Override failed #{payload['gate_kind'].to_s.humanize} evidence"

    def presentation_detail
      [
        "#{payload['gate_identity']} at #{payload['candidate_head_sha'].to_s.first(12)}",
        "Evidence: #{payload['evidence_digest'].to_s.first(12)}",
        "Diagnosis: #{payload['diagnosis']}",
        "Remediation attempted: #{payload['remediation_attempted']}",
        "Consequence: #{payload['consequence']}",
        ("Bug report: #{payload['bug_report_url']}" if payload['bug_report_url'].present?)
      ].compact.join("\n")
    end

    repairs_job!
  end
end
