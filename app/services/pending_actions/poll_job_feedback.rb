module PendingActions
  class PollJobFeedback < Base
    action_key "poll_job_feedback"

    def execute
      job = accessible_action_job
      unless job.open? && job.pr_number.present?
        raise ArgumentError, "Can only check feedback on open Jobs that have a PR."
      end

      progress!("Queueing PR feedback poll for #{job.slug}...")
      PollPullRequestJob.perform_later(job.id, manual: true)
      nil
    end

    def execution_label
      "Queueing PR feedback poll..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
    end

    def action_detail
      "job_id: #{payload["job_id"]}"
    end

    def presentation_label
      "Poll PR feedback for #{presentation_job_slug}"
    end

    def tool_card_outcome
      if payload["pr_number"].blank? || payload["pr_url"].blank?
        scope = user.admin? ? Job.all : Job.accessible_to(user)
        job = scope.find_by(id: payload["job_id"])
      end
      pr_number = payload["pr_number"].presence || job&.pr_number
      pr_url = payload["pr_url"].presence || (App::Presentation.job_pr_url(job) if job)
      return if pr_number.blank? || pr_url.blank?

      { pr_number: pr_number, pr_url: pr_url }
    end
  end
end
