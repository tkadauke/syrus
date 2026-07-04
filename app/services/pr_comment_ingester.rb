class PrCommentIngester
  Result = Data.define(:qualifying_records, :non_qualifying_records) do
    def any_qualifying? = qualifying_records.any?
  end

  def self.call(job:, comments:, pr_type:, comment_kind:, user:, agent_provider:)
    new(job: job, comments: comments, pr_type: pr_type, comment_kind: comment_kind,
        user: user, agent_provider: agent_provider).call
  end

  def initialize(job:, comments:, pr_type:, comment_kind:, user:, agent_provider:)
    @job = job
    @comments = comments
    @pr_type = pr_type
    @comment_kind = comment_kind
    @user = user
    @agent_provider = agent_provider
  end

  def call
    qualifying = []
    non_qualifying = []

    @comments.each do |comment|
      record = ingest_comment(comment)
      next unless record

      if qualifies_for_workflow?(record)
        qualifying << record
      else
        non_qualifying << record
      end
    end

    Result.new(qualifying_records: qualifying, non_qualifying_records: non_qualifying)
  end

  private

  def ingest_comment(comment)
    comment_id = comment.respond_to?(:id) ? comment.id : nil
    return nil unless comment_id

    existing = PrReviewComment.find_by(
      job: @job,
      pr_type: @pr_type,
      comment_kind: @comment_kind,
      github_comment_id: comment_id
    )
    return nil if existing

    github_handle = comment.user&.login.to_s.presence
    attributed_to = PrCommentAttributor.call(github_handle: github_handle.to_s, job: @job)
    actionable = classify_actionable(comment.body)

    PrReviewComment.create!(
      job: @job,
      pr_type: @pr_type,
      comment_kind: @comment_kind,
      github_comment_id: comment_id,
      github_handle: github_handle,
      attributed_to: attributed_to,
      actionable: actionable,
      body: comment.body,
      comment_created_at: comment.created_at
    )
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def classify_actionable(body)
    return true if body.blank?

    result = PrCommentClassifier.call(
      body: body,
      user: @user,
      agent_provider: @agent_provider
    )

    if result.error
      Rails.logger.warn("[PrCommentIngester] classification failed (#{result.error}); defaulting to actionable=true")
      return true
    end

    result.actionable
  end

  def qualifies_for_workflow?(record)
    return false unless record.actionable?
    return true if record.job_owner?

    @job.repository.feedback_policy_auto?
  end
end
