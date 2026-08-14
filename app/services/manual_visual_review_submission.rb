# Dispatches a standalone Workflows::ManualVisualReview run for a Job.
# Shared between the operator-facing "Run visual review" job action and
# the chat-triggerable run_visual_review pending action, mirroring how
# ChatFeedbackSubmission backs both the chat_feedback controller action
# and submit_chat_feedback.
class ManualVisualReviewSubmission
  Result = Data.define(:workflow, :run, :error) do
    def success? = error.blank?
  end

  def self.call(job:)
    unless job.visual_review_runnable?
      return Result.new(workflow: nil, run: nil, error: "Visual review can only be run on implemented or approved Jobs with no active run.")
    end

    unless RepoVisualReviewPlan.for_job(job).enabled?
      return Result.new(workflow: nil, run: nil, error: "Visual review is not configured for this repository.")
    end

    workflow = Workflows::ManualVisualReview.instantiate(job: job)
    run = StepDispatcher.start_workflow(workflow)

    Result.new(workflow: workflow, run: run, error: nil)
  end
end
