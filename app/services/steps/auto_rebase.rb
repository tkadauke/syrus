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

      if result.succeeded?
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

    def skip_agent_rebase!(reason:)
      next_step = step.next_step
      return unless next_step&.kind == "agent_rebase"
      return unless next_step.may_skip?

      log("[#{step.kind}] skipping downstream step ##{next_step.id} (#{next_step.kind}): #{reason}")
      next_step.skip_with_reason!(reason)
    end
  end
end
