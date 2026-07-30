module Steps
  # Merges an approved external PR via GitHub's merge API.
  # Closes the Job on success; raises StepFailed on merge failures
  # (conflicts, failing required status checks, etc.).
  class ExternalPrMerge < Base
    TRANSIENT_MERGE_ERRORS = [
      Octokit::Conflict,
      Octokit::ServiceUnavailable,
      Octokit::InternalServerError
    ].freeze

    def call
      client = GithubClient.for(repository: repository, user: job.user)
      pr = client.pull_request(repository.slug, job.external_pr_number)

      if pr.state == "closed"
        log("external_pr_merge: PR ##{job.external_pr_number} is already closed", kind: "system")
        close_job_for_closed_pr!(pr)
        cancel_workflow!
        return
      end

      merge_result = merge_pull_request(client)
      return unless merge_result

      merged = merge_result.respond_to?(:merged) ? merge_result.merged : merge_result[:merged]
      raise StepFailed, "external_pr_merge: GitHub did not report PR ##{job.external_pr_number} as merged" unless merged

      job.close_with_reason!("external_pr_merged") if job.open?
      log("external_pr_merge: merged external PR ##{job.external_pr_number}")
    end

    private

    def merge_pull_request(client)
      client.merge_pull_request(
        repository.slug,
        job.external_pr_number,
        commit_title: "Merge #{repository.slug}##{job.external_pr_number} via Syrus",
        merge_method: "rebase"
      )
    rescue Octokit::MethodNotAllowed => e
      raise StepFailed, "external_pr_merge: GitHub merge failed: #{e.message}"
    rescue *TRANSIENT_MERGE_ERRORS => e
      defer_after_transient_error!(e)
      nil
    rescue Octokit::Error => e
      raise StepFailed, "external_pr_merge: GitHub merge failed: #{e.message}"
    end

    def defer_after_transient_error!(error)
      log("external_pr_merge: deferred - #{error.message.to_s.first(121)}", kind: "system")
      job.defer_landing! if job.may_defer_landing?
      job.save! if job.changed?
      cancel_workflow!
    end

    def close_job_for_closed_pr!(pr)
      return unless job.open?

      reason = pr.merged ? "external_pr_merged" : "external_pr_closed"
      job.close_with_reason!(reason)
    end

    def cancel_workflow!
      run.cancel! if run.may_cancel?
      run.save!
      step.cancel! if step.may_cancel?
      step.save!
      workflow.cancel! if workflow.may_cancel?
      workflow.save!
    end
  end
end
