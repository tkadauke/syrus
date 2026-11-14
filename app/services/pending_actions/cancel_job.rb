module PendingActions
  class CancelJob < Base
    action_key "cancel_job"

    repairs_job!

    def execute
      eligibility = JobCancellationEligibility.call(job: action_job)
      raise ArgumentError, eligibility.message unless eligibility.eligible?
      if action_job.landed_sha.present? || action_job.deployment_stage_statuses.exists?
        raise ArgumentError, "#{action_job.slug} has landing or deployment evidence and cannot be cancelled."
      end

      canonical_job = accessible_canonical_job

      progress!("Cancelling active work for #{action_job.slug}...")
      StateTransition.with_source("operator", user:, reason: closure_reason(canonical_job), metadata: audit_metadata(canonical_job)) do
        action_job.transaction do
          action_job.lock!
          action_job.cancel_active_execution!
          action_job.update!(canonical_job: canonical_job)
          action_job.close_with_reason!(closure_reason(canonical_job))
        end
      end
      action_job.reload
    end

    def execution_label
      "Cancelling job..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:payload, "reason is too long") if payload["reason"].to_s.length > 1_000
    end

    def action_detail
      "job_id: #{payload["job_id"]}, reason: #{payload["reason"]}"
    end

    def presentation_label
      "Cancel #{presentation_job_slug}"
    end

    def presentation_detail = payload["reason"].to_s

    private

    def accessible_canonical_job
      return if payload["canonical_job_id"].blank?

      replacement = user.admin? ? Job.find(payload["canonical_job_id"]) : Job.visible_to(user).find(payload["canonical_job_id"])
      if replacement == action_job || replacement.repository_id != action_job.repository_id
        raise ArgumentError, "canonical_job_id must reference another accessible Job in the same repository"
      end
      replacement
    end

    def closure_reason(canonical_job) = canonical_job ? "duplicate" : "cancelled"

    def audit_metadata(canonical_job)
      actor = action.subject || user
      {
        "actor_type" => actor.class.polymorphic_name,
        "actor_id" => actor.id,
        "chat_session_id" => action.chat_session_id,
        "human_reason" => payload["reason"].presence || action.reason.presence || "Operator cancelled Job.",
        "canonical_job_id" => canonical_job&.id,
        "requested_action" => "cancel"
      }.compact
    end
  end
end
