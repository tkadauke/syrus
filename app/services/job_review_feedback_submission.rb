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
    unless eligible?(source_job)
      return Result.new(job: nil, error: "Feedback can only be requested once this Job has been implemented and successfully landed or is awaiting landing.")
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

  # previewable? (implemented/approved/landing) covers "still open"; a closed
  # Job only counts as "already landed" when it closed for a successful
  # reason. A Job closed as e.g. invalidated/duplicate/cancelled must NOT be
  # eligible — depending on it would create a JobDependency that can never
  # be satisfied (JobDependencies#dependency_succeeded? requires closed? AND
  # a successful closure_reason), permanently stranding the new Job in
  # "triaging".
  def self.eligible?(source_job)
    source_job.previewable? ||
      (source_job.closed? && Job::SUCCESSFUL_CLOSURE_REASONS.include?(source_job.closure_reason))
  end
  private_class_method :eligible?
end
