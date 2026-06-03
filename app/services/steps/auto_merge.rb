module Steps
  class AutoMerge < Base
    TRANSIENT_MERGE_ERRORS = [
      Octokit::Conflict,
      Octokit::ServiceUnavailable,
      Octokit::InternalServerError
    ].freeze
    NON_RETRYABLE_REBASE_MERGE_ERROR = /(?:can(?:not|'t)|could not) be rebased/i

    def call
      client = GithubClient.for(repository: repository, user: job.user)

      if waiting_for_parent_merge?
        queue_until_parent_merges!
        return
      end

      gate = AutoMergeGate.new(job: job, client: client, bypass_cache: true).evaluate
      persist_mergeable(gate.pr)

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
        job.close_with_reason!("pr_closed") if job.open?
        cancel_workflow!
        return
      when :transient
        log("auto_merge: deferred - mergeable_state=#{deferred_mergeable_state(gate)}", kind: "system")
        defer_landing_if_possible!
        cancel_workflow!
        return
      when :needs_rebase
        handle_needs_rebase!(gate)
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
    rescue Octokit::MethodNotAllowed => e
      if retryable_method_not_allowed?(e)
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
      !NON_RETRYABLE_REBASE_MERGE_ERROR.match?(error.message.to_s)
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

    # Send the Job back to :approved so the landing queue isn't
    # blocked by a Job in :landing with no active auto_merge
    # workflow. The approval persists across the defer; the queue
    # will re-attempt landing once the blocker clears. Idempotent.
    def defer_landing_if_possible!
      return unless job.may_defer_landing?

      job.defer_landing!
      job.save! if job.changed?
    end

    def persist_mergeable(pr)
      return unless pr&.respond_to?(:mergeable)

      job.update!(
        pr_mergeable: pr.mergeable,
        pr_mergeable_checked_at: Time.current
      )
    end

    # PR's mergeable_state is `behind` or `dirty`. Both are
    # recoverable via the agent-driven rebase chain (auto_rebase →
    # agent_rebase → force_push). Trigger the rebase inline if one
    # isn't already running and we haven't hit the consecutive-
    # failure cap — when the rebase succeeds, Workflow#succeed's
    # dispatch_post_rebase_landing! re-fires auto_merge without
    # waiting for the next LandingQueueProcessor tick.
    #
    # Loop guard: if PollRebaseJob::REBASE_ATTEMPT_CAP consecutive
    # rebase workflows have failed, fail_landing instead — the
    # operator needs to intervene (manual rebase, conflict
    # resolution offline, etc.) before we burn more agent turns.
    def handle_needs_rebase!(gate)
      if RebaseLoopGuard.noop_rebase_for?(job: job, pr: gate.pr)
        log("auto_merge: deferred - mergeable_state=#{deferred_mergeable_state(gate)}; latest rebase was a no-op for this PR head/base, waiting for GitHub mergeability to refresh", kind: "system")
        defer_landing_if_possible!
        cancel_workflow!
        return
      end

      if rebase_attempt_cap_reached?
        log("auto_merge: needs_rebase but #{PollRebaseJob::REBASE_ATTEMPT_CAP} consecutive rebase attempts have failed; failing landing", kind: "system")
        raise StepFailed, "auto_merge: #{gate.reason} and rebase cap reached"
      end

      log("auto_merge: deferred - mergeable_state=#{deferred_mergeable_state(gate)}; dispatching rebase workflow inline", kind: "system")
      defer_landing_if_possible!

      unless rebase_workflow_active?
        rebase_workflow = RebaseWorkflowSelector.instantiate(job: job, pr: gate.pr)
        log("auto_merge: dispatched rebase workflow ##{rebase_workflow.id}", kind: "system")
        StepDispatcher.start_workflow(rebase_workflow)
      end

      cancel_workflow!
    end

    def rebase_workflow_active?
      RebaseWorkflowSelector.active_for_stack?(job)
    end

    def rebase_attempt_cap_reached?
      consecutive = 0
      job.workflows.where(trigger_kind: RebaseWorkflowSelector::TRIGGER_KINDS).reorder(id: :desc).each do |workflow|
        break if workflow.succeeded?
        consecutive += 1 if workflow.failed?
      end
      consecutive >= PollRebaseJob::REBASE_ATTEMPT_CAP
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
