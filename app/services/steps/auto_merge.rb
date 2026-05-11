module Steps
  class AutoMerge < Base
    def call
      client = GithubClient.for(job.user)
      gate = AutoMergeGate.new(job: job, client: client, bypass_cache: true).evaluate

      if gate.closed?
        log("auto_merge: PR ##{job.pr_number} is already closed; cancelling workflow")
        cancel_workflow!
        return
      end

      raise StepFailed, "auto_merge: #{gate.reason}" unless gate.merge_ready?

      merge = client.merge_pull_request(
        repository.slug,
        job.pr_number,
        commit_title: "Merge #{repository.slug}##{job.pr_number} via Syrus",
        merge_method: "rebase"
      )
      raise StepFailed, "auto_merge: GitHub did not report the PR as merged" unless merge.respond_to?(:merged) ? merge.merged : merge[:merged]

      comment = "Merged automatically by Syrus after approval and green checks. Job ##{job.id}: #{job_url}"
      client.add_issue_comment(repository.slug, job.pr_number, comment)
      job.close_with_reason!("pr_merged") if job.open?
      log("auto_merge: merged PR ##{job.pr_number}")
    end

    private

    def cancel_workflow!
      run.cancel! if run.may_cancel?
      run.save!
      step.cancel! if step.may_cancel?
      step.save!
      workflow.cancel! if workflow.may_cancel?
      workflow.save!
    end

    def job_url
      Rails.application.routes.url_helpers.job_url(
        job,
        host: ENV.fetch("SYRUS_APP_HOST", "localhost")
      )
    rescue StandardError
      "job #{job.id}"
    end
  end
end
