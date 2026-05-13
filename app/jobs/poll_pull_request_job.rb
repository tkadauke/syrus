class PollPullRequestJob < ApplicationJob
  queue_as :default

  # One concurrent poll per Job — same Job's poll fanout shouldn't race
  # the watermark or stack two pr_comment Runs at once.
  limits_concurrency to: 1, key: ->(job_id, *) { "pr_poll:#{job_id}" }

  # `manual: true` is set by JobsController#poll_feedback (operator
  # clicked the "Check for PR feedback" button). Keep the flag in
  # the signature for controller/backward compatibility; PR-comment
  # polling is watermark-driven and has no autonomous cap.
  def perform(job_id, manual: false, agent_provider: nil)
    @agent_provider = agent_provider.presence
    @job = Job.find_by(id: job_id)
    return unless @job&.open? && @job.pr_number.present?
    return if @job.repository.archived?

    @client = GithubClient.for(repository: @job.repository, user: @job.user)
    @slug = @job.repository.slug
    @pr = @client.pull_request(@slug, @job.pr_number)

    # Reaching this point means the user's GH token is at least
    # readable for pull_request — clear any stale "API blocked"
    # banner. Per-branch errors below mark it again if needed.
    @job.user.clear_gh_api_blocked!

    return close_with("pr_merged") if @pr.merged
    return close_with("pr_closed") if @pr.state == "closed"
    return close_with("syrus_stop") if has_label?(@pr, "syrus-stop")
    return close_with("pr_approved") if any_new_approval?

    react_to_pr_comments
  rescue Octokit::Forbidden, Octokit::Unauthorized => e
    # The pull_request fetch itself failed on permissions — record
    # for the banner, then re-raise so SolidQueue's failed_executions
    # table reflects the actual error class for later diagnostics.
    @job&.user&.mark_gh_api_blocked!(strip_docs_url(e.message))
    raise
  end

  private

  def close_with(reason)
    Rails.logger.info("[PollPullRequestJob] closing job #{@job.id}: #{reason}")
    @job.runs.active.find_each do |r|
      r.cancel! if r.may_cancel?
      r.save!
    end
    @job.close_with_reason!(reason)
  end

  def has_label?(pr, name)
    Array(pr.labels).any? { |l| l.name == name }
  end

  def any_new_approval?
    reviews = @client.pr_reviews(@slug, @job.pr_number)
    cutoff = feedback_cutoff
    reviews.any? do |r|
      r.state == "APPROVED" && (cutoff.nil? || (r.submitted_at && r.submitted_at > cutoff))
    end
  end

  # ----- pr_comment branch ------------------------------------------------

  # `last_seen_comment_at` is a strict watermark that advances past
  # every comment a workflow has reacted to, so repeated polls of a
  # quiet PR enqueue zero workflows. Syrus has no bot identity yet —
  # it pushes commits, doesn't comment — so there's no self-loop to
  # prevent. The operator can fold 50 rounds of feedback into 50
  # follow-up workflows; the watermark guarantees each comment is
  # processed exactly once.
  def react_to_pr_comments
    return if pending_followup?

    new_comments = fetch_new_comments
    return if new_comments.empty?

    enqueue_followup_run(new_comments)
  end

  def pending_followup?
    @job.workflows.active.where(trigger_kind: "pr_comment").exists?
  end

  # We don't filter by author. Syrus runs under the operator's PAT today
  # and doesn't post comments via the API — only pushes commits — so
  # there's no self-loop to prevent. The operator IS the reviewer; their
  # comments are exactly what we want to act on. When/if Syrus gets its
  # own bot identity (separate GitHub account or App), add a configurable
  # skip-by-login filter back here.
  def fetch_new_comments
    cutoff = feedback_cutoff
    issue_comments = @client.pr_issue_comments(@slug, @job.pr_number, since: cutoff)
    review_comments = @client.pr_review_comments(@slug, @job.pr_number, since: cutoff)
    (issue_comments + review_comments)
      .select { |comment| cutoff.nil? || (comment.created_at && comment.created_at > cutoff) }
      .sort_by(&:created_at)
  end

  def enqueue_followup_run(new_comments)
    # Stash the comment payload on the workflow as a structured
    # artifact; Steps::Respond reads it at run time and composes
    # the Prompts::PrFeedback prompt itself. Polling job stays
    # ignorant of prompt internals.
    artifacts = {
      "pr_comments" => new_comments.map { |c| serialize_comment(c) }
    }
    workflow = Workflows::PrFeedback.instantiate(job: @job, artifacts: artifacts, agent_provider: @agent_provider)
    StepDispatcher.start_workflow(workflow)

    latest = new_comments.map(&:created_at).compact.max
    @job.update!(last_seen_comment_at: latest) if latest && (@job.last_seen_comment_at.nil? || latest > @job.last_seen_comment_at)
  end

  def feedback_cutoff
    [ @job.last_seen_comment_at, @job.last_feedback_addressed_at ].compact.max
  end

  # Octokit returns Sawyer::Resource objects; serialize to a plain
  # hash that round-trips through Workflow.artifacts (JSON column).
  def serialize_comment(c)
    {
      "author"     => c.user&.login,
      "body"       => c.body,
      "path"       => (c.respond_to?(:path) ? c.path : nil),
      "line"       => (c.respond_to?(:line) ? c.line : nil),
      "diff_hunk"  => (c.respond_to?(:diff_hunk) ? c.diff_hunk : nil),
      "created_at" => c.created_at&.iso8601
    }
  end

  # Octokit error messages are shaped:
  #   "GET https://...: 403 - <real message> // See: <docs_url>"
  # We want the operator-facing slice (everything before the
  # ` // See:` documentation pointer) but split-on-`//` would
  # eat the URL's own protocol prefix. Anchor on " // " (with
  # spaces) to preserve the URL.
  def strip_docs_url(message)
    message.to_s.split(/ \/\/ /, 2).first.to_s.strip
  end

end
