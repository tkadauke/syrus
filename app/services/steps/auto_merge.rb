module Steps
  class AutoMerge < Base
    include AutoMergeControl

    TRANSIENT_MERGE_ERRORS = [
      Octokit::Conflict,
      Octokit::ServiceUnavailable,
      Octokit::InternalServerError
    ].freeze
    REBASE_MERGE_REJECTED_ERROR = /(?:can(?:not|'t)|could not) be rebased/i

    # GitHub computes PR mergeability asynchronously: for a few
    # seconds after a push the API returns mergeable_state="unknown"
    # while it recomputes. The push step immediately precedes this
    # step, so a naive check almost always sees "unknown" right after
    # our own push. Deferring on that first "unknown" cancels the
    # whole workflow and throws away a completed, green grader run —
    # the next landing attempt then re-grades from scratch. Instead,
    # poll a few times for the state to settle before giving up; it
    # usually resolves to "clean" within a few seconds and merges.
    MERGEABILITY_SETTLE_ATTEMPTS = 5
    MERGEABILITY_SETTLE_DELAY = 3.seconds

    class << self
      # Test seam: specs set this to 0 so the settle loop never sleeps.
      attr_writer :mergeability_settle_delay

      def mergeability_settle_delay
        @mergeability_settle_delay || MERGEABILITY_SETTLE_DELAY
      end
    end

    def call
      client = GithubClient.for(repository: repository, user: job.user)

      if waiting_for_parent_merge?
        queue_until_parent_merges!
        return
      end

      gate = settle_transient_mergeability(client)
      persist_github_mergeability(gate.pr)

      # Every early-exit path here must transition the Job out of
      # :landing before cancelling the workflow — otherwise
      # LandingQueueProcessor keeps treating that repository as
      # occupied. defer_landing preserves the approval and sends the
      # Job back to :approved so it re-enters the landing queue after
      # the blocker clears; the :closed case closes the Job to match
      # the PR.
      case gate.outcome
      when :closed
        log("auto_merge: PR ##{job.pr_number} is already closed; cancelling workflow", kind: "system")
        close_job_for_closed_pull_request!(gate.pr, client)
        cancel_workflow!
        return
      when :transient
        log("auto_merge: deferred - mergeable_state=#{deferred_mergeable_state(gate)}", kind: "system")
        defer_landing_if_possible!
        cancel_workflow!
        return
      when :needs_rebase
        handle_needs_rebase!(gate, client: client)
        return
      end

      raise StepFailed, "auto_merge: #{gate.reason}" unless gate.merge_ready?

      merge = merge_pull_request(client, gate)
      return unless merge

      raise StepFailed, "auto_merge: GitHub did not report the PR as merged" unless merge.respond_to?(:merged) ? merge.merged : merge[:merged]

      comment = "Merged automatically by Syrus after approval and green checks. #{job.slug}: #{job_url}"
      add_merge_comment(client, comment)
      job.close_with_reason!("pr_merged") if job.open?
      if job.branch_name.present?
        job.update_column(:branch_deleted_at, Time.current) if client.delete_branch(repository.slug, job.branch_name)
      end
      log("auto_merge: merged PR ##{job.pr_number}")
    end

    private

    # Evaluate the merge gate, but if GitHub reports a transient
    # mergeable_state (it's still recomputing after our push), poll a
    # bounded number of times for it to resolve before returning.
    # Returns the first non-transient gate, or the last transient gate
    # if the budget is exhausted (the caller's :transient branch then
    # defers as before).
    def settle_transient_mergeability(client)
      gate = evaluate_gate(client)
      return gate unless gate.transient?

      MERGEABILITY_SETTLE_ATTEMPTS.times do |attempt|
        log(
          "auto_merge: mergeable_state=#{deferred_mergeable_state(gate)} (GitHub still computing after push); waiting for it to settle (attempt #{attempt + 1}/#{MERGEABILITY_SETTLE_ATTEMPTS})",
          kind: "system"
        )
        settle_sleep
        gate = evaluate_gate(client)
        break unless gate.transient?
      end

      gate
    end

    def evaluate_gate(client)
      AutoMergeGate.new(job: job, client: client, bypass_cache: true).evaluate
    end

    def close_job_for_closed_pull_request!(pr, client)
      return unless job.open?

      job.close_with_reason!(ClosedPullRequestResolution.reason(job: job, pr: pr, client: client))
    end

    def settle_sleep
      delay = self.class.mergeability_settle_delay.to_f
      sleep(delay) if delay.positive?
    end

    def merge_pull_request(client, gate)
      client.merge_pull_request(
        repository.slug,
        job.pr_number,
        commit_title: "Merge #{repository.slug}##{job.pr_number} via Syrus",
        merge_method: "rebase"
      )
    rescue Octokit::MethodNotAllowed => e
      if rebase_merge_rejected?(e)
        handle_rebase_merge_rejection!(gate, e, client: client)
        nil
      elsif retryable_method_not_allowed?(e)
        defer_after_transient_merge_error!(e)
        nil
      else
        raise StepFailed, "auto_merge: GitHub merge failed: #{e.message}"
      end
    rescue *TRANSIENT_MERGE_ERRORS => e
      defer_after_transient_merge_error!(e)
      nil
    rescue Octokit::Error => e
      raise StepFailed, "auto_merge: GitHub merge failed: #{e.message}"
    end

    def defer_after_transient_merge_error!(error)
      log("auto_merge: deferred - #{transient_error_message(error)}", kind: "system")
      job.defer_landing! if job.may_defer_landing?
      job.save! if job.changed?
      cancel_workflow!
    end

    def retryable_method_not_allowed?(error)
      !rebase_merge_rejected?(error)
    end

    def rebase_merge_rejected?(error)
      REBASE_MERGE_REJECTED_ERROR.match?(error.message.to_s)
    end

    def handle_rebase_merge_rejection!(gate, error, client:)
      reason = "GitHub rejected rebase merge: #{transient_error_message(error)}"
      rebase_gate = AutoMergeGate::Result.new(
        outcome: :needs_rebase,
        approved: gate.approved?,
        reason: reason,
        pr: gate.pr
      )
      handle_needs_rebase!(rebase_gate, defer_reason: reason, client: client)
    end

    def transient_error_message(error)
      error.message.to_s[0, 121]
    end

    def add_merge_comment(client, comment)
      client.add_issue_comment(repository.slug, job.pr_number, comment)
    rescue Octokit::TooManyRequests, Octokit::Error => e
      log("auto_merge: cleanup could not comment on PR ##{job.pr_number}: #{e.class}: #{e.message}", kind: "system")
    end

    def waiting_for_parent_merge?
      parent = job.parent_job
      return false unless parent

      !(parent.closed? && parent.closure_reason == "pr_merged")
    end

    def queue_until_parent_merges!
      parent = job.parent_job
      workflow.set_artifact!("pending_auto_merge", "waiting_for_parent")
      log("auto_merge: waiting for parent #{parent.slug} to merge; queued auto-merge will re-evaluate after stack rebase", kind: "system")
      cancel_workflow!
    end

    def job_url
      Rails.application.routes.url_helpers.job_url(
        job,
        host: ENV.fetch("SYRUS_APP_HOST", "localhost")
      )
    rescue StandardError
      job.slug
    end
  end
end
