class DiffReviewCommentFeedbackSubmission
  ACTIONABLE_STATES = %w[draft submitted].freeze
  ALLOWED_JOB_STATES = %w[implemented approved failed].freeze

  Result = Data.define(:workflow, :comments, :error) do
    def success? = error.blank?
  end

  def self.call(job:, comment_ids:, actor:)
    new(job: job, comment_ids: comment_ids, actor: actor).call
  end

  def initialize(job:, comment_ids:, actor:)
    @job = job
    @comment_ids = Array(comment_ids).filter_map { |id| id.to_s.presence&.to_i }.uniq
    @actor = actor
  end

  def call
    return Result.new(workflow: nil, comments: [], error: "Select at least one diff comment to submit.") if comment_ids.empty?

    comments = selected_comments
    return Result.new(workflow: nil, comments: [], error: "No unresolved diff comments were selected.") if comments.empty?

    result = ChatFeedbackSubmission.call(
      job: job,
      feedback: feedback_body(comments),
      allowed_states: ALLOWED_JOB_STATES,
      extra_artifacts: {
        "feedback_source" => feedback_source(comments),
        "diff_comments" => comments.map { |comment| structured_comment(comment) }
      }
    )
    return Result.new(workflow: nil, comments: comments, error: result.error) unless result.success?

    comments.each { |comment| mark_submitted!(comment, result.workflow) }

    Result.new(workflow: result.workflow, comments: comments, error: nil)
  rescue ActiveRecord::RecordInvalid => e
    Result.new(workflow: nil, comments: [], error: e.record.errors.full_messages.to_sentence)
  end

  private

  attr_reader :job, :comment_ids, :actor

  def selected_comments
    job.diff_review_comments
       .includes(:user)
       .where(id: comment_ids, state: ACTIONABLE_STATES)
       .ordered
       .to_a
  end

  def feedback_body(comments)
    header = "Please address these #{comments.size} anchored diff review #{'comment'.pluralize(comments.size)}."
    ([ header ] + comments.map { |comment| readable_comment(comment) }).join("\n\n")
  end

  def readable_comment(comment)
    <<~COMMENT.strip
      - #{comment.path}:#{display_line(comment)} (#{comment.side})
        #{comment.body}
    COMMENT
  end

  def display_line(comment)
    comment.side == "left" ? comment.old_line : comment.new_line
  end

  def feedback_source(comments)
    {
      "kind" => "diff_review_comments",
      "diff_review_comment_ids" => comments.map(&:id),
      "confirmed_by" => "operator",
      "submitted_by_user_id" => actor&.id
    }
  end

  def structured_comment(comment)
    {
      "id" => comment.id,
      "path" => comment.path,
      "side" => comment.side,
      "old_line" => comment.old_line,
      "new_line" => comment.new_line,
      "line" => display_line(comment),
      "base_ref" => comment.base_ref,
      "head_ref" => comment.head_ref,
      "diff_hunk" => comment.diff_hunk,
      "context" => comment.context || {},
      "body" => comment.body,
      "author" => comment.user&.display_name || comment.user&.email_address,
      "created_at" => comment.created_at&.iso8601
    }
  end

  def mark_submitted!(comment, workflow)
    comment.update!(state: "submitted", workflow: workflow, submitted_at: Time.current)
  end
end
