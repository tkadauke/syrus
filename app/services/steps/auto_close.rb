module Steps
  # Non-agentic terminal step that closes the anchor Job. Used by the
  # AgentInsight workflow chain so the Job closes as part of normal step
  # progression rather than only in after_success / after_fail hooks.
  class AutoClose < Base
    def call
      StateTransition.with_source("system") do
        job.close_with_reason!("agent_insight") if job.may_close?
      end
    end
  end
end
