module Steps
  # First step of Rebase workflow. Non-agentic: invokes the
  # AutoRebase service (deterministic `git rebase origin/<base>`).
  # On success the deterministic rebase resolved without agent
  # help, so this step skips AgentRebase and lets ForcePush run.
  #
  # On conflict, lets the chain proceed to AgentRebase.
  class AutoRebase < Base
    def call
      log("auto_rebase: attempting deterministic rebase (#{workflow.slug})")
      result = auto_rebase.call
      workflow.set_artifact!("auto_rebase_result", result.to_h)

      if result.reason == ::AutoRebase::ALREADY_LANDED_REASON
        log("auto_rebase: #{result.note}")
        skip_agent_rebase!(reason: "auto_rebase found the work already on the base; nothing to rebase")
        finalize_already_landed!
      elsif result.succeeded?
        log("auto_rebase: clean — #{result.note}")
        skip_agent_rebase!(reason: "auto_rebase already succeeded; agent rebase not needed")
      else
        workflow.set_artifact!("auto_rebase_reason", result.reason)
        log("auto_rebase: #{result.reason} — falling through to agent_rebase")
      end
    end

    private

    def rebase_base_branch
      RebaseTarget.branch_for(job: job, workflow: workflow)
    end

    def rebase_source_branch
      RebaseTarget.source_branch_for(job: job, workflow: workflow)
    end

    def auto_rebase
      kwargs = { base_branch: rebase_base_branch }
      kwargs[:branch_name] = rebase_source_branch if rebase_source_branch.present?
      ::AutoRebase.new(job, **kwargs)
    end

    # The branch holds nothing the base doesn't, so this Job landed -- almost
    # always through a merge train whose member reconciliation could not verify
    # it and left the Job open. Recording that here is what stops the poller
    # from dispatching rebase after rebase against work that is already in.
    #
    # Best-effort throughout: a Job we cannot close, or a PR GitHub will not
    # let us comment on, must not fail a rebase that itself did nothing wrong.
    def finalize_already_landed!
      if job.may_close?
        job.close_with_reason!("pr_merged")
        log("auto_rebase: #{job.slug} closed as pr_merged — its commits are already on #{rebase_base_branch}")
      else
        log("auto_rebase: #{job.slug} is #{job.state} and was left as-is; its commits are already on #{rebase_base_branch}")
      end

      close_landed_pull_request!
    rescue StandardError => e
      log("auto_rebase: could not finalize #{job.slug} as landed: #{e.class}: #{e.message}")
    end

    def close_landed_pull_request!
      return if job.pr_number.blank?

      client = GithubClient.for(repository: repository, user: job.user)
      client.add_issue_comment(
        repository.slug, job.pr_number,
        "Closing: every commit on `#{job.branch_name}` is already on `#{rebase_base_branch}`, " \
        "so this PR has nothing left to merge. Syrus recorded #{job.slug} as landed."
      )
      client.close_pull_request(repository.slug, job.pr_number)
    end

    def skip_agent_rebase!(reason:)
      next_step = step.next_step
      return unless next_step&.kind == "agent_rebase"
      return unless next_step.may_skip?

      log("[#{step.kind}] skipping downstream step ##{next_step.id} (#{next_step.kind}): #{reason}")
      next_step.skip_with_reason!(reason)
    end
  end
end
