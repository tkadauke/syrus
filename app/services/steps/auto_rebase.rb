module Steps
  # First step of Rebase workflow. Non-agentic: invokes the
  # AutoRebase service (deterministic `git rebase origin/<base>`).
  # On success the deterministic rebase resolved without agent
  # help, so this step skips AgentRebase and lets ForcePush run.
  #
  # On conflict, lets the chain proceed to AgentRebase.
  class AutoRebase < Base
    def call
      log("auto_rebase: attempting deterministic rebase (workflow ##{workflow.id})")
      result = ::AutoRebase.new(job).call

      if result.succeeded?
        log("auto_rebase: clean — #{result.note}")
        cancel_agent_rebase!(reason: "auto_rebase already succeeded; agent rebase not needed")
      else
        workflow.set_artifact!("auto_rebase_reason", result.reason)
        log("auto_rebase: #{result.reason} — falling through to agent_rebase")
      end
    end

    private

    def cancel_agent_rebase!(reason:)
      next_step = step.next_step
      return unless next_step&.kind == "agent_rebase"
      return unless next_step.may_cancel?

      log("[#{step.kind}] cancelling downstream step ##{next_step.id} (#{next_step.kind}): #{reason}")
      next_step.cancel!
      next_step.save!
    end
  end
end
