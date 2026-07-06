module PendingActions
  class CheckJobMergeability < Base
    action_key "check_job_mergeability"

    def execute
      job = action_user_job
      unless job.pr_number.present? || job.external_pr_number.present?
        raise ArgumentError, "No PR on this Job to check."
      end

      PollRebaseJob.perform_later(job.id, bypass_cache: true)
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
