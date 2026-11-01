# Dispatches a standalone Workflows::ManualVisualReview run for a Job.
# Shared between the operator-facing "Run visual review" job action and
# the chat-triggerable run_visual_review pending action, mirroring how
# ChatFeedbackSubmission backs both the chat_feedback controller action
# and submit_chat_feedback.
class ManualVisualReviewSubmission
  MAX_PROMPT_LENGTH = 4_000
  Result = Data.define(:workflow, :run, :error) do
    def success? = error.blank?
  end

  def self.call(job:, prompt: nil)
    prompt = prompt.to_s.strip if prompt
    if prompt && prompt.blank?
      return Result.new(workflow: nil, run: nil, error: "Visual review instructions cannot be blank.")
    end
    if prompt&.length.to_i > MAX_PROMPT_LENGTH
      return Result.new(workflow: nil, run: nil, error: "Visual review instructions must be #{MAX_PROMPT_LENGTH} characters or fewer.")
    end

    unless job.visual_review_runnable?
      return Result.new(workflow: nil, run: nil, error: "Visual review can only be run on implemented or approved Jobs with no active run.")
    end

    unless RepoVisualReviewPlan.for_job(job).enabled?
      return Result.new(workflow: nil, run: nil, error: "Visual review is not configured for this repository.")
    end

    artifacts = { "manual_visual_review_instructions" => prompt }.compact
    result = WorkUnits::Launcher.create_and_start!(kind: "manual_visual_review", job: job, artifacts: artifacts)

    Result.new(workflow: result.workflow, run: result.run, error: nil)
  end
end
