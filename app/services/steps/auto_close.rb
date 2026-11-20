module Steps
  # Non-agentic terminal step that closes the anchor Job -- with its own
  # kind as the closure reason, the same convention Job#mark_infrastructure_job_closed
  # uses -- for :infrastructure Jobs (an insight sweep, a grader pass).
  # Workflows whose Job has no PR and no operator review end with this
  # step so the Job closes as part of normal step progression rather than
  # only in after_success / after_fail hooks.
  #
  # The close itself is recorded on the Workflow and applied when it
  # finishes (JobClosure), like every Workflow-initiated close. A Job that
  # cannot close fails the step here rather than stranding it open with no
  # visible failure anywhere.
  class AutoClose < Base
    def call
      job.reload
      return if job.closed?
      raise StepFailed, "auto_close ran but #{job.slug} is #{job.state} and cannot close" unless job.may_close?

      workflow.request_job_closure!(job, job.kind)
    end
  end
end
