module PendingActions
  class ForceFailJob < Base
    action_key "force_fail_job"

    def execute
      raise ArgumentError, "Admin access required." unless user.admin?

      job = Job.find(payload.fetch("job_id"))
      raise ArgumentError, "#{job.slug} is #{job.state} and cannot be force-failed." unless job.may_force_fail?

      job.force_fail!
      job
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "job_id: #{payload["job_id"]}"
    end

    def repair_action?
      true
    end

    def repair_snapshot_targets
      [ repair_action_job_or_nil ]
    end
  end
end
