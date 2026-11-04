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
    classification = classify(comment)
    actionable = classification[:actionable]

    record = PrReviewComment.create!(
      job: @job,
      pr_type: @pr_type,
      comment_kind: @comment_kind,
      github_comment_id: comment_id,
      github_handle: github_handle,
      attributed_to: attributed_to,
      actionable: actionable,
      classification_decision: classification[:decision],
      classification_reason: classification[:reason].to_s.truncate(255).presence,
      classification_source: classification[:source],
      classifier_version: classification[:version],
      classification_error: classification[:error].to_s.truncate(255).presence,
      body: comment.body,
      comment_created_at: comment.created_at,
      path: value_for(comment, :path),
      side: value_for(comment, :side),
      line: integer_value_for(comment, :line),
      start_line: integer_value_for(comment, :start_line),
      original_line: integer_value_for(comment, :original_line),
      original_start_line: integer_value_for(comment, :original_start_line)
    )
    gate = qualification_gate(record)
    record.update_columns(qualified_for_workflow: gate == "qualified", qualification_gate: gate)
    record
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def value_for(comment, key)
    comment.public_send(key) if comment.respond_to?(key)
  end

  def integer_value_for(comment, key)
    Integer(value_for(comment, key), exception: false)
  end

  # Returns the audit hash persisted on the comment. Classification is advisory
  # only: authorization is decided separately by #qualification_gate.
  def classify(comment)
    body = comment.body
    return audit(true, "empty_body", "empty body treated as actionable", "rule") if body.blank?
    return audit(false, "skipped_bot", "Syrus-generated report comment", "rule") if syrus_report_comment?(comment)
    return audit(false, "skipped_bot", "authored by a bot account", "rule") if bot_comment?(comment)
    return audit(false, "quoted_only", "body consists only of quoted text", "rule") if quoted_only?(body)

    result = PrCommentClassifier.call(body: body, user: @user, agent_provider: @agent_provider)

    if result.error
      Rails.logger.warn("[PrCommentIngester] classification failed (#{result.error}); failing closed (actionable=false)")
      return audit(false, "error", nil, "model", version: result.version, error: result.error)
    end

    audit(result.actionable, result.actionable ? "actionable" : "not_actionable", result.reason, "model", version: result.version)
  end

  def audit(actionable, decision, reason, source, version: nil, error: nil)
    { actionable: actionable, decision: decision, reason: reason, source: source, version: version, error: error }
  end

  # A comment whose every non-blank line is a Markdown quote ("> ...") only
  # repeats someone else's words; it never carries the author's own request.
  def quoted_only?(body)
    lines = body.to_s.lines.map(&:strip).reject(&:empty?)
    lines.any? && lines.all? { |line| line.start_with?(">") }
  end

  def bot_comment?(comment)
    user = comment.respond_to?(:user) ? comment.user : nil
    return false unless user
    return true if user.respond_to?(:type) && user.type.to_s.casecmp?("Bot")

    user.respond_to?(:login) && user.login.to_s.end_with?("[bot]")
  end

  def syrus_report_comment?(comment)
    return false unless BotIdentity.for(@job).authored_github_comment?(comment)

    body = comment.body.to_s
    body.include?(CoverageReport::PrCommentFormatter::MARKER) ||
      body.include?(DependencyAuditReport::PrCommentFormatter::MARKER)
  end

  def qualifies_for_workflow?(record)
    record.qualified_for_workflow?
  end

  # Authorization gates are independent of the model decision: a comment
  # qualifies only when it is classified actionable AND the author/policy
  # gates pass. Returns "qualified" or the first gate that blocked it.
  def qualification_gate(record)
    return "not_actionable" unless record.actionable?
    return "qualified" if @pr_type == "fork_review" && record.external?
    return "qualified" if record.job_owner?
    return "qualified" if record.member? && @job.repository.feedback_policy_auto?
    return "feedback_policy" if record.member?

    "unauthorized_author"
  end
end
