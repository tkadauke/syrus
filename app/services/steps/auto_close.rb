module Steps
  # Non-agentic terminal step that closes the anchor Job. Used by the
  # AgentInsight workflow chain so the Job closes as part of normal step
  # progression rather than only in after_success / after_fail hooks.
  #
  # `job.may_close?` is a check-then-act read outside a lock; without
  # the row lock + post-condition check below, a concurrent write between
  # the check and Job#close_with_reason! could silently no-op the close
  # while this step (and its Run) still reports success — stranding the
  # Job open with no visible failure anywhere (see JOB-3302). Locking and
  # verifying the end state turns that into a raised, retryable failure
  # instead of a silent one.
  class AutoClose < Base
    def call
      job.with_lock do
        job.reload
        next if job.closed?

        StateTransition.with_source("system") do
          job.close_with_reason!("agent_insight") if job.may_close?
        end
      end

      raise StepFailed, "auto_close ran but Job ##{job.id} is still #{job.state}, not closed" unless job.closed?
    end
  end
end
