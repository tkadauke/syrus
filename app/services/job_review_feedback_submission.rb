# Files feedback against a Job as a new standalone Job rather than amending
# the source Job in place. This is the job-centric replacement for
# Epic#append_review_feedback_job! (EPIC-258): instead of appending onto an
# Epic's linear chain, it creates a plain direct Job that depends on the
# source Job via the existing mode-agnostic JobDependency mechanism, and
# lands independently through the normal approval/auto_merge path.
class JobReviewFeedbackSubmission
  Result = Data.define(:job, :error) do
    def success? = error.blank?
  end

  def self.call(source_job:, feedback:, actor:)
    feedback = feedback.to_s.strip
    return Result.new(job: nil, error: "Feedback can't be blank.") if feedback.blank?
    unless source_job.previewable? || source_job.closed?
      return Result.new(job: nil, error: "Feedback can only be requested once this Job has been implemented.")
    end

    job = nil
    ActiveRecord::Base.transaction do
      job = source_job.user.jobs.create!(
        repository: source_job.repository,
        kind: "direct",
        issue_number: nil,
        issue_title: "Review feedback: #{source_job.issue_title}",
        issue_body: feedback,
        agent_provider: source_job.repository.effective_agent_provider,
        priority: "medium",
        state: "triaging",
        owner_user: actor || source_job.owner_user || source_job.user
      )

      job.dependencies.create!(
        depends_on_job: source_job,
        source: "manual",
        created_by_user: actor || source_job.user
      )

      job.advance_after_triage! if job.may_advance_after_triage?
    end

    Result.new(job: job, error: nil)
  rescue ActiveRecord::RecordInvalid => e
    Result.new(job: nil, error: e.record.errors.full_messages.to_sentence)
  end
end
