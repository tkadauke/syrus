module PendingActions
  class CloseJobSuccessfully < Base
    action_key "close_job_successfully"

    def execute
      job = action_permitted_job
      reason = payload.fetch("closure_reason")
      raise ArgumentError, "#{reason} is not a successful Job closure reason." unless successful_reason?(reason)
      raise ArgumentError, "#{job.slug} is already closed." if job.closed?
      raise ArgumentError, "#{job.slug} cannot be closed from #{job.state}." unless job.may_close?

      github_result = close_job_and_pull_request(job, reason)
      action.update_column(:payload, payload.merge("github_result" => github_result))
      job
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?

      reason = payload["closure_reason"]
      if reason.blank?
        errors.add(:payload, "closure_reason is required")
      elsif !successful_reason?(reason)
        errors.add(:payload, "closure_reason must be one of #{Job::SUCCESSFUL_CLOSURE_REASONS.join(', ')}")
      end
    end

    def action_detail
      "job_id: #{payload["job_id"]}, closure_reason: #{payload["closure_reason"]}"
    end

    private

    def successful_reason?(reason)
      Job::SUCCESSFUL_CLOSURE_REASONS.include?(reason.to_s)
    end

    def action_permitted_job
      (user.admin? ? Job.all : user.jobs).find(payload.fetch("job_id"))
    end

    def close_job_and_pull_request(job, reason)
      github_result = github_closure_result(job)

      ApplicationRecord.transaction do
        cancel_active_execution!(job)
        job.update!(grace_period_expires_at: nil)
        job.close_with_reason!(reason)
      end

      close_pull_request_if_present(job, github_result)
      github_result
    end

    def cancel_active_execution!(job)
      job.workflows.active.find_each do |workflow|
        workflow.cancel! if workflow.may_cancel?
        workflow.save!
      end

      job.runs.active.find_each do |run|
        run.cancel! if run.may_cancel?
        run.save!
      end
    end

    def github_closure_result(job)
      return { "status" => "not_applicable", "message" => "Job has no tracked PR." } unless job.pr_number.present?

      { "status" => "pending", "repo_slug" => job.effective_pr_repository.slug, "pr_number" => job.pr_number }
    end

    def close_pull_request_if_present(job, result)
      return unless result["status"] == "pending"

      unless github_credentials_available?(job)
        result["status"] = "skipped"
        result["message"] = "No GitHub credentials were available to comment on or close PR ##{job.pr_number}."
        return
      end

      client = GithubClient.for(repository: job.effective_pr_repository, user: job.user)
      result["comment"] = post_comment(client, result["repo_slug"], job.pr_number)
      result["close"] = close_pull_request(client, result["repo_slug"], job.pr_number)
      result["status"] = result.values_at("comment", "close").any? { |entry| entry["status"] == "failed" } ? "partial_failure" : "closed"
    rescue => e
      result["status"] = "partial_failure"
      result["close"] = failure_result(e)
    end

    def github_credentials_available?(job)
      GithubClient.active_installation_for(repository: job.effective_pr_repository, user: job.user).present? ||
        job.user.github_token.present?
    end

    def post_comment(client, repo_slug, pr_number)
      comment = payload["comment"].to_s.strip
      return { "status" => "skipped", "message" => "No comment supplied." } if comment.blank?

      client.add_issue_comment(repo_slug, pr_number, comment, on_behalf_of: user)
      { "status" => "posted" }
    rescue => e
      failure_result(e)
    end

    def close_pull_request(client, repo_slug, pr_number)
      client.close_pull_request(repo_slug, pr_number)
      { "status" => "closed" }
    rescue => e
      failure_result(e)
    end

    def failure_result(error)
      { "status" => "failed", "error" => "#{error.class}: #{error.message}" }
    end
  end
end
