module PendingActions
  class CheckJobMergeability < Base
    action_key "check_job_mergeability"

    def execute
      job = user.jobs.find_by(id: payload.fetch("job_id"))
      raise ArgumentError, "Job is not accessible." unless job

      unless job.pr_number.present? || job.external_pr_number.present?
        raise ArgumentError, "No PR on this Job to check."
      end

      PollRebaseJob.enqueue_manual_check(job.id)
      nil
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
    end

    def action_detail
      "job_id: #{payload["job_id"]}"
    end
  end
end
