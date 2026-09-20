module PendingActions
  class ForceFailJob < Base
    action_key "force_fail_job"
    admin_only!

    def execute
      job = Job.find(payload.fetch("job_id"))
      raise ArgumentError, "#{job.slug} is #{job.state} and cannot be force-failed." unless job.may_force_fail?

      progress!("Marking #{job.slug} failed...")
      job.force_fail!
      job
    end

    def execution_label
      "Force-failing job..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "job_id: #{payload["job_id"]}"
    end

    def presentation_label
      "Force fail #{presentation_job_slug}"
    end

    def repair_action?
      true
    end

    def repair_snapshot_targets
      [ repair_action_job_or_nil ]
    end
  end
end
