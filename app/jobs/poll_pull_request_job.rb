class PollPullRequestJob < ApplicationJob
  queue_as :default

  # Max ci_failure workflows on a Job in any rolling 24h window. CI
  # failures CAN runaway loop (agent's fix introduces new failures →
  # push → CI runs on new sha → another ci_failure workflow → repeat),
  # since each successful agent push advances head_sha and resets the
  # `last_ci_handled_sha` watermark. The 24h window means a long-quiet
  # Job recovers a fresh budget naturally; lifetime caps prevented
  # recovery forever, which was wrong.
  CI_FAILURE_WINDOW = 24.hours
  CI_FAILURE_CAP = 3

  # One concurrent poll per Job — same Job's poll fanout shouldn't race
  # the watermark or stack two pr_comment Runs at once.
  limits_concurrency to: 1, key: ->(job_id, *) { "pr_poll:#{job_id}" }

  # `manual: true` is set by the Job detail feedback command (operator
  # clicked the "Check for PR feedback" button). The pr_comment /
  # ci_failure caps are runaway-loop defenses for the autonomous
  # 5-minute poller; the operator clicking the button is an
  # explicit override of that defense, so we skip the cap checks
  # in that path. Without this, the button silently no-ops on Jobs
  # that have already burned through their pr_comment quota.
  def perform(job_id, manual: false, agent_provider: nil)
    @manual = manual
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

    react_to_pr_reviews
    react_to_pr_comments
    react_to_ci_failures
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
    StackRebaseCoordinator.parent_closed(@job) if reason == "pr_closed"
  end

  def has_label?(pr, name)
    Array(pr.labels).any? { |l| l.name == name }
  end

  def react_to_pr_reviews
    latest_approval = @client.pr_reviews(@slug, @job.pr_number)
                             .select { |review| review.state == "APPROVED" }
                             .max_by { |review| review_submitted_at(review) || Time.at(0) }
    return unless latest_approval

    submitted_at = review_submitted_at(latest_approval) || Time.current
    return if @job.approved_at && @job.approved_at >= submitted_at

    @job.record_github_review_approval!(
      approved_at: submitted_at,
      review_url: latest_approval.respond_to?(:html_url) ? latest_approval.html_url : nil
    )
  end

  def review_submitted_at(review)
    value = review.respond_to?(:submitted_at) ? review.submitted_at : nil
    return value if value.respond_to?(:to_time) && !value.is_a?(String)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  # ----- pr_comment branch ------------------------------------------------

  # No cap here: `last_seen_comment_at` is a strict watermark that
  # advances past every comment a workflow has reacted to, so repeated
  # polls of a quiet PR enqueue zero workflows. Syrus has no bot
  # identity yet — it pushes commits, doesn't comment — so there's no
  # self-loop the way ci_failure has. The operator can fold 50 rounds
  # of feedback into 50 follow-up workflows; the watermark guarantees
  # each comment is processed exactly once.
  def react_to_pr_comments
    return if pending_followup?
    return if provider_circuit_open?("pr_comment")

    cutoff = feedback_cutoff
    all_comments = fetch_all_comments
    new_comments = all_comments.select do |comment|
      cutoff.nil? || (comment.created_at && comment.created_at > cutoff)
    end
    return if new_comments.empty?

    enqueue_followup_run(all_comments: all_comments, new_comments: new_comments, cutoff: cutoff)
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
  #
  # Fetches the FULL comment thread (no `since:` cutoff), not just new
  # comments since the watermark. The agent needs the prior comments
  # too — otherwise it loses the arc of the conversation and
  # oscillates: addresses feedback in round N, reverts in round N+1,
  # re-adds in round N+2. The new-vs-prior distinction is preserved
  # by tagging in the artifact so the prompt can flag what's
  # actionable this round.
  def fetch_all_comments
    issue_comments = @client.pr_issue_comments(@slug, @job.pr_number)
    review_comments = @client.pr_review_comments(@slug, @job.pr_number)
    (issue_comments + review_comments).sort_by(&:created_at)
  end

  def enqueue_followup_run(all_comments:, new_comments:, cutoff:)
    ingest_comment_images(new_comments)

    # Stash the full comment payload + the cutoff timestamp on the
    # workflow as a structured artifact; Steps::Respond reads it at
    # run time and composes the Prompts::PrFeedback prompt itself.
    # Polling job stays ignorant of prompt internals.
    artifacts = {
      "pr_comments" => all_comments.map { |c| serialize_comment(c) },
      "feedback_cutoff" => cutoff&.iso8601
    }
    workflow = Workflows::PrFeedback.instantiate(job: @job, artifacts: artifacts, agent_provider: @agent_provider)
    StepDispatcher.start_workflow(workflow)

    latest = new_comments.map(&:created_at).compact.max
    @job.update!(last_seen_comment_at: latest) if latest && (@job.last_seen_comment_at.nil? || latest > @job.last_seen_comment_at)
  end

  def ingest_comment_images(new_comments)
    new_comments.each do |comment|
      JobImageAttachmentIngestor.ingest_markdown_images(job: @job, markdown: comment.body)
    end
  end

  def feedback_cutoff
    return @job.last_feedback_addressed_at if @manual

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

  # ----- ci_failure branch -----------------------------------------------

  def react_to_ci_failures
    head_sha = @pr.head&.sha
    return unless head_sha.present?
    return if @job.last_ci_handled_sha == head_sha   # already reacted to this commit
    return if ci_failure_cap_reached?
    return if pending_ci_failure_run?
    return if provider_circuit_open?("ci_failure")

    failed = @client.failed_check_runs_for(@slug, head_sha)
    return if failed.empty?

    enqueue_ci_failure_run(head_sha, failed)
  rescue Octokit::Forbidden, Octokit::Unauthorized => e
    # Check-runs requires `Checks: read` (fine-grained) or `repo`
    # (classic). PR-comment polling above doesn't, so we treat
    # check-runs as best-effort: record the failure on the user
    # for the banner, log, and let the rest of the poll proceed.
    # Pre-existing pr_comment Runs that already enqueued this poll
    # shouldn't all die because CI scope is missing.
    reason = strip_docs_url(e.message)
    @job.user.mark_gh_api_blocked!("check-runs: #{reason}")
    Rails.logger.warn("[PollPullRequestJob] job #{@job.id}: ci_failure path disabled — #{reason[0, 160]}")
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

  # Rolling-window cap: max CI_FAILURE_CAP ci_failure workflows in
  # the last CI_FAILURE_WINDOW. Lifetime caps left long-running Jobs
  # permanently locked out after burning through their budget; a
  # rolling window lets a Job recover after the loop quiets down.
  def ci_failure_cap_reached?
    return false if @manual  # operator-initiated polls bypass autopoll defenses
    recent = @job.workflows.where(trigger_kind: "ci_failure")
                           .where("created_at >= ?", CI_FAILURE_WINDOW.ago)
                           .count
    return false unless recent >= CI_FAILURE_CAP
    Rails.logger.info("[PollPullRequestJob] job #{@job.id} hit ci_failure cap (#{CI_FAILURE_CAP} in #{CI_FAILURE_WINDOW.inspect}); skipping")
    true
  end

  def pending_ci_failure_run?
    @job.workflows.active.where(trigger_kind: "ci_failure").exists?
  end

  def provider_circuit_open?(trigger_kind)
    return false if @manual

    circuit = ProviderCircuitBreaker.call(@agent_provider.presence || @job.agent_provider)
    return false unless circuit.open?

    Rails.logger.info(
      "[PollPullRequestJob] job #{@job.id}: #{trigger_kind} suppressed because #{circuit.provider} circuit is open " \
      "(#{circuit.reason}, failures=#{circuit.failure_count}, jobs=#{circuit.job_count}, retry_after=#{circuit.retry_after})"
    )
    true
  end

  def enqueue_ci_failure_run(head_sha, failed_checks)
    failed_checks = failed_checks.map { |check| enrich_failed_check(check) }
    artifacts = {
      "head_sha"      => head_sha,
      "failed_checks" => failed_checks
    }
    workflow = Workflows::CiFailure.instantiate(job: @job, artifacts: artifacts, agent_provider: @agent_provider)
    StepDispatcher.start_workflow(workflow)
    @job.update!(last_ci_handled_sha: head_sha)
    Rails.logger.info("[PollPullRequestJob] job #{@job.id}: enqueued CiFailure workflow ##{workflow.id} for #{head_sha[0..6]} (#{failed_checks.size} failing)")
  end

  def enrich_failed_check(check)
    check = check.to_h
    name = check[:name] || check["name"]
    summary = check[:summary] || check["summary"]
    log = check.delete(:log) || check.delete("log")
    full_log_url = check[:html_url] || check["html_url"]
    parser_input = log.presence || summary.to_s

    check.merge(
      error_context: CiLogParser.new(
        parser_input,
        step_name: name,
        full_log_url: full_log_url
      ).parse
    )
  end
end
