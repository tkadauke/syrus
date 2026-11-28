module PendingActions
  class CloseJobSuccessfully < Base
    action_key "close_job_successfully"

    def execute
      job = action_permitted_job
      reason = payload.fetch("closure_reason")
      validate_reason!(reason)
      raise ArgumentError, "#{job.slug} is already closed." if job.closed?
      raise ArgumentError, "#{job.slug} cannot be closed from #{job.state}." unless job.may_close?

      progress!("Closing #{job.slug} as #{reason}...")
      github_result = close_job_and_pull_request(job, reason)
      progress!("Recording closure result...")
      action.update_column(:payload, payload.merge("github_result" => github_result))
      job
    end

    def execution_label
      "Closing job successfully..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?

      reason = payload["closure_reason"]
      if reason.blank?
        errors.add(:payload, "closure_reason is required")
      elsif !Job::ClosureReason.by_reason.key?(reason.to_s)
        errors.add(:payload, "closure_reason is not registered")
      elsif reason.to_s == "cancelled"
        errors.add(:payload, "cancelled is reserved for a human close without a reason")
      else
        definition = Job::ClosureReason.fetch(reason)
        errors.add(:payload, "references are required") if definition.requires_reference && Array(payload["references"]).empty?
        errors.add(:payload, "note is required") if definition.requires_note && payload["note"].to_s.strip.blank?
        errors.add(:payload, "canonical_job_id is required for duplicate") if reason.to_s == "duplicate" && payload["canonical_job_id"].blank?
      end
    end

    def action_detail
      "job_id: #{payload["job_id"]}, closure_reason: #{payload["closure_reason"]}"
    end

    def presentation_label
      "Close #{presentation_job_slug} as #{payload["closure_reason"]}"
    end

    def presentation_detail
      payload["comment"].presence
    end

    private

    def validate_reason!(reason)
      raise ArgumentError, "cancelled is reserved for a human close without a reason" if reason.to_s == "cancelled"
      definition = Job::ClosureReason.fetch(reason)
      raise ArgumentError, "#{reason} requires references" if definition.requires_reference && Array(payload["references"]).empty?
      raise ArgumentError, "#{reason} requires a note" if definition.requires_note && payload["note"].to_s.strip.blank?
    end

    def action_permitted_job
      (user.admin? ? Job.all : user.jobs).find(payload.fetch("job_id"))
    end

    def close_job_and_pull_request(job, reason)
      github_result = github_closure_result(job)

      # Announced before the transaction: a progress write is a write to the
      # pending action, and one made inside this transaction is undone if it
      # rolls back.
      progress!("Cancelling active workflows and runs...")
      ApplicationRecord.transaction do
        cancel_active_execution!(job)
        job.update!(grace_period_expires_at: nil, canonical_job: canonical_job(job, reason))
        StateTransition.with_source("tool", user:, reason:, metadata: closure_metadata) do
          job.close_with_reason!(reason, references: payload["references"], note: payload["note"])
        end
      end

      progress!("Closing tracked pull request if needed...")
      close_pull_request_if_present(job, github_result)
      github_result
    end

    def cancel_active_execution!(job)
      job.cancel_active_execution!
    end

    def closure_metadata
      {
        "actor_type" => closure_actor_type,
        "actor_id" => action.subject&.id,
        "actor_record_type" => action.subject&.class&.polymorphic_name,
        "actor_record_id" => action.subject&.id,
        "chat_session_id" => action.chat_session_id,
        "references" => payload["references"],
        "note" => payload["note"]
      }.compact
    end

    def closure_actor_type
      actor = action.subject
      return actor.kind.to_s if actor&.respond_to?(:kind)
      return "agent" if action.requested_by == "agent"

      "human"
    end

    def canonical_job(job, reason)
      return unless reason.to_s == "duplicate"

      canonical = (user.admin? ? Job.all : Job.visible_to(user)).find(payload.fetch("canonical_job_id"))
      if canonical == job || canonical.repository_id != job.repository_id
        raise ArgumentError, "duplicate must reference another accessible Job in the same repository"
      end
      canonical
    end

    def github_closure_result(job)
      pr_number = job.pr_number.presence || job.external_pr_number.presence
      return { "status" => "not_applicable", "message" => "Job has no tracked PR." } unless pr_number

      { "status" => "pending", "repo_slug" => job.effective_pr_repository.slug, "pr_number" => pr_number }
    end

    def close_pull_request_if_present(job, result)
      return unless result["status"] == "pending"

      unless github_credentials_available?(job)
        result["status"] = "skipped"
        result["message"] = "No GitHub credentials were available to comment on or close PR ##{job.pr_number}."
        return
      end

      client = GithubClient.for(repository: job.effective_pr_repository, user: job.user)
      result["comment"] = post_comment(client, result["repo_slug"], result.fetch("pr_number"))
      result["close"] = close_pull_request(client, result["repo_slug"], result.fetch("pr_number"))
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
