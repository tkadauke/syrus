module Steps
  class AutoMerge < Base
    TRANSIENT_MERGE_ERRORS = [
      Octokit::MethodNotAllowed,
      Octokit::Conflict,
      Octokit::ServiceUnavailable,
      Octokit::InternalServerError
    ].freeze

    def call
      client = GithubClient.for(repository: repository, user: job.user)

      if waiting_for_parent_merge?
        queue_until_parent_merges!
        return
      end

      gate = AutoMergeGate.new(job: job, client: client, bypass_cache: true).evaluate

      case gate.outcome
      when :closed
        log("auto_merge: PR ##{job.pr_number} is already closed; cancelling workflow", kind: "system")
        cancel_workflow!
        return
      when :transient
        log("auto_merge: deferred - mergeable_state=#{deferred_mergeable_state(gate)}", kind: "system")
        cancel_workflow!
        return
      when :needs_rebase
        log("auto_merge: deferred - mergeable_state=#{deferred_mergeable_state(gate)}; rebase workflow will handle it", kind: "system")
        cancel_workflow!
        return
      end

      raise StepFailed, "auto_merge: #{gate.reason}" unless gate.merge_ready?

      merge = merge_pull_request(client)
      return unless merge

      raise StepFailed, "auto_merge: GitHub did not report the PR as merged" unless merge.respond_to?(:merged) ? merge.merged : merge[:merged]

      comment = "Merged automatically by Syrus after approval and green checks. Job ##{job.id}: #{job_url}"
      client.add_issue_comment(repository.slug, job.pr_number, comment)
      job.close_with_reason!("pr_merged") if job.open?
      log("auto_merge: merged PR ##{job.pr_number}")
    end

    private

    def merge_pull_request(client)
      client.merge_pull_request(
        repository.slug,
        job.pr_number,
        commit_title: "Merge #{repository.slug}##{job.pr_number} via Syrus",
        merge_method: "rebase"
      )
    rescue *TRANSIENT_MERGE_ERRORS => e
      log("auto_merge: deferred - #{transient_error_message(e)}", kind: "system")
      job.defer_landing! if job.may_defer_landing?
      job.save! if job.changed?
      cancel_workflow!
      nil
    rescue Octokit::Error => e
      raise StepFailed, "auto_merge: GitHub merge failed: #{e.message}"
    end

    def transient_error_message(error)
      error.message.to_s[0, 121]
    end

    def waiting_for_parent_merge?
      parent = job.parent_job
      return false unless parent

      !(parent.closed? && parent.closure_reason == "pr_merged")
    end

    def queue_until_parent_merges!
      parent = job.parent_job
      workflow.set_artifact!("pending_auto_merge", "waiting_for_parent")
      log("auto_merge: waiting for parent ##{parent.pr_number || parent.id} to merge; queued auto-merge will re-evaluate after stack rebase", kind: "system")
      cancel_workflow!
    end

    def cancel_workflow!
      run.cancel! if run.may_cancel?
      run.save!
      step.cancel! if step.may_cancel?
      step.save!
      workflow.cancel! if workflow.may_cancel?
      workflow.save!
    end

    def deferred_mergeable_state(gate)
      pr = gate.pr
      state = pr.mergeable_state if pr.respond_to?(:mergeable_state)
      state || "nil"
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
