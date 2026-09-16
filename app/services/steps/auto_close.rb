module Steps
  # Non-agentic terminal step that closes the anchor Job -- with its own
  # kind as the closure reason, the same convention Job#mark_infrastructure_job_closed
  # uses -- for :infrastructure Jobs (an insight sweep, a grader pass).
  # Workflows whose Job has no PR and no operator review end with this
  # step so the Job closes as part of normal step progression rather than
  # only in after_success / after_fail hooks.
  #
  # Investigation Jobs are first-class (operator-visible, not infrastructure),
  # so `job.kind` (always "direct") would collapse into the same generic
  # reason every other direct Job's ordinary implement/PR flow could produce.
  # They close with a distinct, successful reason instead so a submitted
  # report reads as a real completion, not a no-op.
  #
  # `job.may_close?` is a check-then-act read outside a lock; without
  # the row lock + post-condition check below, a concurrent write between
  # the check and Job#close_with_reason! could silently no-op the close
  # while this step (and its Run) still reports success — stranding the
  # Job open with no visible failure anywhere. Locking and
  # verifying the end state turns that into a raised, retryable failure
  # instead of a silent one.
  class AutoClose < Base
    INVESTIGATION_CLOSURE_REASON = "investigation_reported".freeze

    def call
      job.with_lock do
        job.reload
        next if job.closed?

        StateTransition.with_source("system") do
          job.close_with_reason!(closure_reason) if job.may_close?
        end
      end

      raise StepFailed, "auto_close ran but #{job.slug} is still #{job.state}, not closed" unless job.closed?
    end

    private

    def closure_reason
      job.investigation? ? INVESTIGATION_CLOSURE_REASON : job.kind
    end
  end
end
