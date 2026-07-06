module PendingActions
  class PollJobFeedback < Base
    action_key "poll_job_feedback"

    def execute
      job = action_user_job
      unless job.open? && job.pr_number.present?
        raise ArgumentError, "Can only check feedback on open Jobs that have a PR."
      end

      PollPullRequestJob.perform_later(job.id, manual: true)
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
