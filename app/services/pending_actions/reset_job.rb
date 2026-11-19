module PendingActions
  class ResetJob < Base
    action_key "reset_job"
    admin_only!
    repairs_job!

    def perform
      progress!("Resetting #{repair_action_job.slug} from scratch...")
      ResetJobs::Operation.new(job: repair_action_job, user:, reason:, pending_action: action).call
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:reason, "is required") if reason.blank?
      error = ResetJobs::Operation.preflight(repair_action_job_or_nil) if repair_action_job_or_nil
      errors.add(:payload, error) if error
    end

    def presentation_label = "Reset #{presentation_job_slug}"
    def presentation_detail
      summary = ResetJobs::Operation.destruction_summary(repair_action_job_or_nil)
      [ reason, ("PR ##{summary[:open_pr_number]}" if summary[:open_pr_number]), summary[:branch],
        ("#{summary[:checkpoints]} checkpoints" if summary[:checkpoints].to_i.positive?),
        ("Active Workflows: #{summary[:active_workflows].join(', ')}" if summary[:active_workflows].any?) ].compact.join("\n")
    end
  end
end
