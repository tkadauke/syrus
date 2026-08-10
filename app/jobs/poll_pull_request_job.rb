class PollPullRequestJob < ApplicationJob
  include GithubPrPollHelpers

  queue_as :polling

  # Max ci_failure workflows on a Job in any rolling 24h window. CI
  # failures CAN runaway loop (agent's fix introduces new failures →
  # push → CI runs on new sha → another ci_failure workflow → repeat),
  # since each successful agent push advances head_sha and resets the
  # `last_ci_handled_sha` watermark. The 24h window means a long-quiet
  # Job recovers a fresh budget naturally; lifetime caps prevented
  # recovery forever, which was wrong.
  CI_FAILURE_WINDOW = 24.hours
  CI_FAILURE_CAP = 3
  NO_EFFECTIVE_CI_REPAIR_REASON = "CI repair made no effective change and checks are still failing"

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

    pr_repo = @job.effective_pr_repository
    @client = GithubClient.for(repository: pr_repo, user: @job.user)
    @slug = pr_repo.slug
    @pr = @client.pull_request(@slug, @job.pr_number)

    # Reaching this point means the user's GH token is at least
    # readable for pull_request — clear any stale "API blocked"
    # banner. Per-branch errors below mark it again if needed.
    @job.user.clear_gh_api_blocked!

    return close_with("pr_merged") if @pr.merged
    return handle_upstream_pr_reopened if upstream_pr_was_reopened?

    if @pr.state == "closed"
      handle_upstream_pr_closed
      return
    end

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

  # ----- upstream PR closed / grace period -----------------------------------

  def upstream_pr_was_reopened?
    @pr.state == "open" && @job.needs_attention_reason == "upstream_pr_closed"
  end

  def handle_upstream_pr_reopened
    Rails.logger.info("[PollPullRequestJob] #{@job.slug}: upstream PR reopened; clearing grace period")
    @job.clear_needs_attention!
    @job.cancel_grace_period!
    # Resume normal polling for this cycle.
    react_to_pr_reviews
    react_to_pr_comments
    react_to_ci_failures
  end

  def handle_upstream_pr_closed
    if @job.in_grace_period? && @job.needs_attention_reason == "upstream_pr_closed"
      # Still in grace period, still closed — do nothing until expiry or reopen.
      return
    end

    reason = closed_pull_request_reason
    if reason == "pr_merged"
      # Shouldn't reach here (we guard on @pr.merged above), but handle defensively.
      close_with("pr_merged")
      return
    end

    if reason == "no_changes"
      close_with("no_changes")
      return
    end

    # Closed without merge: set needs_attention + start grace period.
    @job.set_needs_attention!(reason: "upstream_pr_closed")
    return if @job.grace_period_expires_at.present?

    duration = @job.repository.upstream_pr_grace_period_days.days
    @job.start_grace_period!(duration: duration)
    Rails.logger.info("[PollPullRequestJob] #{@job.slug}: upstream PR closed; grace period #{duration / 86400}d started")

    StackRebaseCoordinator.parent_closed(@job)
  end

  # ----- upstream PR review state --------------------------------------------

  def react_to_pr_reviews
    reviews = @client.pr_reviews(@slug, @job.pr_number)
    react_to_review_state(reviews)

    approvals = reviews.select { |review| review.state == "APPROVED" }
    return if approvals.empty?

    if fork_review_upstream_job? && multi_person_review_policy?
      react_to_upstream_pr_reviews_multi(approvals)
    else
      react_to_pr_reviews_single(approvals)
    end
  end

  def react_to_review_state(reviews)
    if changes_requested?(reviews)
      @job.set_needs_attention!(reason: "upstream_pr_changes_requested")
    elsif @job.needs_attention_reason == "upstream_pr_changes_requested"
      # All CHANGES_REQUESTED reviews are now APPROVED or DISMISSED.
      @job.clear_needs_attention!
    end
  end

  # Returns true if any reviewer's *latest* review is CHANGES_REQUESTED.
  def changes_requested?(reviews)
    latest_per_reviewer(reviews).any? { |review| review.state == "CHANGES_REQUESTED" }
  end

  def latest_per_reviewer(reviews)
    reviews
      .group_by { |review| review.respond_to?(:user) ? review.user&.login : nil }
      .values
      .map { |reviewer_reviews| reviewer_reviews.max_by { |r| review_submitted_at(r) || Time.at(0) } }
      .compact
  end

  # ----- close ---------------------------------------------------------------

  def close_with(reason)
    Rails.logger.info("[PollPullRequestJob] closing #{@job.slug}: #{reason}")
    @job.runs.active.find_each do |r|
      r.cancel! if r.may_cancel?
      r.save!
    end
    @job.update!(grace_period_expires_at: nil)
    @job.close_with_reason!(reason)
    StackRebaseCoordinator.parent_closed(@job) if reason == "pr_closed"

    if @job.branch_name.present? && @job.branch_deleted_at.nil?
      if reason == "pr_merged"
        # Branch lives on the fork (repository), not the upstream (effective_pr_repository)
        delete_fork_branch
      elsif fork_review_upstream_job?
        # For fork-review jobs, the upstream PR being closed (without merge) also means we
        # should clean up the feature branch on the fork and notify the job owner.
        delete_fork_branch
        notify_upstream_pr_closed(reason)
      end
    end
  end

  def delete_fork_branch
    fork_client = GithubClient.for(repository: @job.repository, user: @job.user)
    fork_client.delete_branch(@job.repository.slug, @job.branch_name)
    @job.update_column(:branch_deleted_at, Time.current)
  rescue => e
    Rails.logger.warn("[PollPullRequestJob] #{@job.slug}: could not delete fork branch — #{e.message}")
  end

  def fork_review_upstream_job?
    @job.pr_repository_id.present? && @job.pr_repository_id != @job.repository_id
  end

  def notify_upstream_pr_closed(reason)
    recipient = @job.owner_user || @job.user
    body = "Upstream PR ##{@job.pr_number} for #{@job.slug} was closed without merge: #{@job.title.truncate(80)}"
    body = "Upstream PR ##{@job.pr_number} for #{@job.slug} closed (no changes): #{@job.title.truncate(80)}" if reason == "no_changes"

    NotificationService.create_for(
      user: recipient,
      kind: "upstream_pr_closed",
      job: @job,
      pr_url: App::Presentation.job_pr_url(@job),
      body: body
    )
  rescue => e
    Rails.logger.warn("[PollPullRequestJob] #{@job.slug}: could not send upstream_pr_closed notification — #{e.message}")
  end

  def closed_pull_request_reason
    ClosedPullRequestResolution.reason(job: @job, pr: @pr, client: @client)
  end

  def has_label?(pr, name)
    Array(pr.labels).any? { |l| l.name == name }
  end

  def react_to_pr_reviews_single(approvals)
    latest_approval = approvals.max_by { |review| review_submitted_at(review) || Time.at(0) }
    return unless latest_approval

    sorted = approvals.sort_by { |r| review_submitted_at(r) || Time.at(0) }
    sorted.each do |review|
      submitted_at = review_submitted_at(review) || Time.current
      github_login = review.user&.respond_to?(:login) ? review.user.login : nil
      reviewer_user = github_login.present? ? User.find_by(github_handle: github_login) : nil

      @job.record_github_review_approval!(
        approved_at: submitted_at,
        review_url: review.respond_to?(:html_url) ? review.html_url : nil,
        reviewer_user: reviewer_user
      )
    end
  end

  # For fork-review mode with two_person or final_say policy, we need multiple
  # GitHub approvers on the upstream PR. Each approving reviewer is matched to
  # a Syrus user by github_handle and recorded as a JobApproval. Once the
  # policy's satisfaction condition is met, the job is approved for landing.
  def react_to_upstream_pr_reviews_multi(approvals)
    newly_recorded = false

    approvals.each do |review|
      github_handle = review.user&.login.to_s.presence
      next unless github_handle

      reviewer = User.where("LOWER(github_handle) = ?", github_handle.downcase).first
      next unless reviewer

      approval = @job.job_approvals.find_or_initialize_by(user: reviewer)
      next if approval.persisted?

      approval.save!
      newly_recorded = true
      Rails.logger.info("[PollPullRequestJob] #{@job.slug}: recorded upstream PR approval from @#{github_handle} (user #{reviewer.id})")
    end

    return unless newly_recorded || @job.reload.job_approvals.exists?
    return unless @job.approval_satisfied?
    return unless @job.may_approve?

    @job.approve!(via: "github_review")
  end

  def multi_person_review_policy?
    ReviewPolicies.for(@job.repository.review_policy).new(@job).multi_person?
  end

  # ----- pr_comment branch ------------------------------------------------

  # No cap here: `last_seen_comment_at` is a strict watermark that
  # advances past every non-Syrus-bot comment a workflow has reacted to,
  # so repeated polls of a quiet PR enqueue zero workflows. The operator
  # can fold 50 rounds of feedback into 50 follow-up workflows; the
  # watermark guarantees each human comment is processed exactly once.
  def react_to_pr_comments
    return if pending_followup?
    return if provider_circuit_open?("pr_comment")

    cutoff = feedback_cutoff
    all_comments = fetch_all_comments
    new_comments = all_comments.select do |comment|
      cutoff.nil? || (comment.created_at && comment.created_at > cutoff)
    end
    return if new_comments.empty?

    # Attribute and classify each new comment; only trigger a workflow
    # when at least one qualifies (job-owner actionable, or any actionable
    # when feedback_policy == 'auto').
    ingestion = ingest_new_comments(new_comments)
    return unless ingestion.any_qualifying?

    enqueue_followup_run(
      all_comments: all_comments,
      new_comments: new_comments,
      cutoff: cutoff,
      qualifying_records: ingestion.qualifying_records
    )
  end

  def pending_followup?
    @job.workflows.active.where(trigger_kind: "pr_comment").exists?
  end

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
    reject_syrus_bot_comments(issue_comments + review_comments).sort_by(&:created_at)
  end

  def enqueue_followup_run(all_comments:, new_comments:, cutoff:, qualifying_records: [])
    ingest_comment_images(new_comments)
    clear_stale_approval!

    # Stash the full comment payload + the cutoff timestamp on the
    # workflow as a structured artifact; Steps::Respond reads it at
    # run time and composes the Prompts::PrFeedback prompt itself.
    # Polling job stays ignorant of prompt internals.
    iteration = feedback_iteration_number
    source_handle = qualifying_records.first&.github_handle

    artifacts = {
      "pr_comments" => all_comments.map { |c| serialize_comment(c) },
      "feedback_cutoff" => cutoff&.iso8601,
      "pr_feedback_iteration" => iteration,
      "pr_feedback_auto" => true,
      "pr_feedback_source_handle" => source_handle,
      "pr_review_comment_ids" => qualifying_records.map(&:id)
    }
    workflow = Workflows::PrFeedback.instantiate(job: @job, artifacts: artifacts, agent_provider: @agent_provider)
    StepDispatcher.start_workflow(workflow)

    qualifying_records.each { |r| r.mark_handling_started!(workflow: workflow, by: "auto_poll") }

    latest = new_comments.map(&:created_at).compact.max
    @job.update!(last_seen_comment_at: latest) if latest && (@job.last_seen_comment_at.nil? || latest > @job.last_seen_comment_at)
  end

  def feedback_iteration_number
    @job.workflows.where(trigger_kind: Workflow::TriggerKind.feedback_values).count + 1
  end

  def clear_stale_approval!
    return unless @job.may_unapprove?

    Job::ApprovalUnapprover.call(job: @job, user: @job.user)
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

  def ingest_new_comments(new_comments)
    issue_new = new_comments.reject { |c| c.respond_to?(:path) && c.path.present? }
    review_new = new_comments.select { |c| c.respond_to?(:path) && c.path.present? }

    user = @job.owner_user || @job.user
    provider = @agent_provider.presence || @job.workflow_agent_provider
    pr_type = pr_type_for_job

    issue_result = PrCommentIngester.call(
      job: @job, comments: issue_new, pr_type: pr_type,
      comment_kind: "issue", user: user, agent_provider: provider
    )
    review_result = PrCommentIngester.call(
      job: @job, comments: review_new, pr_type: pr_type,
      comment_kind: "review", user: user, agent_provider: provider
    )

    PrCommentIngester::Result.new(
      qualifying_records: issue_result.qualifying_records + review_result.qualifying_records,
      non_qualifying_records: issue_result.non_qualifying_records + review_result.non_qualifying_records
    )
  end

  def pr_type_for_job
    return "upstream" if @job.pr_repository_id.present? && @job.pr_repository_id != @job.repository_id

    "direct"
  end

  # ----- ci_failure branch -----------------------------------------------

  def react_to_ci_failures
    head_sha = @pr.head&.sha
    return unless head_sha.present?

    # Fetch all check runs in one API call: updates the landing-gate cache
    # (pr_checks_state) AND collects failure details for ci_failure workflows.
    detail = @client.check_runs_detail_for(@slug, head_sha)
    cache_pr_checks_state(head_sha, detail)
    return if ci_infrastructure_failure_only?(head_sha, detail)

    record_no_effective_ci_repair!(head_sha, detail) if no_effective_ci_repair?(head_sha, detail)

    return if @job.last_ci_handled_sha == head_sha   # already reacted to this commit
    return if ci_failure_cap_reached?
    return if pending_ci_failure_run?
    return if provider_circuit_open?("ci_failure")
    return unless detail[:any_failed?]

    enqueue_ci_failure_run(head_sha, detail[:failed_checks])
  rescue Octokit::Forbidden, Octokit::Unauthorized => e
    # Check-runs requires `Checks: read` (fine-grained) or `repo`
    # (classic). PR-comment polling above doesn't, so we treat
    # check-runs as best-effort: record the failure on the user
    # for the banner, log, and let the rest of the poll proceed.
    # Pre-existing pr_comment Runs that already enqueued this poll
    # shouldn't all die because CI scope is missing.
    reason = strip_docs_url(e.message)
    @job.user.mark_gh_api_blocked!("check-runs: #{reason}")
    Rails.logger.warn("[PollPullRequestJob] #{@job.slug}: ci_failure path disabled — #{reason[0, 160]}")
  end

  def cache_pr_checks_state(head_sha, detail)
    state = if detail[:any_failed?] then "failing"
             elsif detail[:pending?] then "pending"
             elsif detail[:all_passed?] then "passing"
             else "unknown"
             end
    attrs = { pr_checks_sha: head_sha, pr_checks_state: state, pr_checks_checked_at: Time.current }
    if no_effective_ci_repair_landing_reason? &&
       (!state.in?(%w[failing pending]) || (@job.pr_checks_sha.present? && @job.pr_checks_sha != head_sha))
      attrs[:landing_failure_reason] = nil
    end
    @job.update_columns(attrs)
  end

  def ci_infrastructure_failure_only?(head_sha, detail)
    failed_checks = Array(detail[:failed_checks] || detail["failed_checks"])
    return false unless failed_checks.any?
    return false unless failed_checks.all? { |check| ci_infrastructure_check?(check) }

    reason = "CI infrastructure failed before repository tests ran on #{head_sha[0, 7]}"
    @job.update!(landing_failure_reason: reason) unless @job.landing_failure_reason == reason
    Rails.logger.info("[PollPullRequestJob] #{@job.slug}: #{reason}; skipping agentic CI repair")
    true
  end

  def ci_infrastructure_check?(check)
    value = check[:failure_kind] || check["failure_kind"]
    value.to_s == "ci_infrastructure"
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

    # Repair jobs must keep absorbing CI feedback until main is fixed.
    return false if @job.main_branch_repair?

    recent = @job.workflows.where(trigger_kind: "ci_failure")
                           .where("created_at >= ?", CI_FAILURE_WINDOW.ago)
                           .count
    return false unless recent >= CI_FAILURE_CAP
    Rails.logger.info("[PollPullRequestJob] #{@job.slug} hit ci_failure cap (#{CI_FAILURE_CAP} in #{CI_FAILURE_WINDOW.inspect}); skipping")
    true
  end

  def pending_ci_failure_run?
    @job.workflows.active.where(trigger_kind: "ci_failure").exists?
  end

  def provider_circuit_open?(trigger_kind)
    return false if @manual

    circuit = ProviderCircuitBreaker.call(@agent_provider.presence || @job.workflow_agent_provider)
    return false unless circuit.open?

    Rails.logger.info(
      "[PollPullRequestJob] #{@job.slug}: #{trigger_kind} suppressed because #{circuit.provider} circuit is open " \
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
    run = StepDispatcher.start_workflow(workflow)
    unless run
      Rails.logger.info("[PollPullRequestJob] #{@job.slug}: created CiFailure workflow ##{workflow.id} for #{head_sha[0..6]} but start was deferred")
      return
    end

    @job.update!(last_ci_handled_sha: head_sha)
    Rails.logger.info("[PollPullRequestJob] #{@job.slug}: enqueued CiFailure workflow ##{workflow.id} for #{head_sha[0..6]} (#{failed_checks.size} failing)")
  end

  def no_effective_ci_repair?(head_sha, detail)
    @job.last_ci_handled_sha == head_sha &&
      (detail[:any_failed?] || detail[:pending?]) &&
      latest_succeeded_ci_failure_for(head_sha).present?
  end

  def latest_succeeded_ci_failure_for(head_sha)
    @latest_succeeded_ci_failure_for ||= {}
    @latest_succeeded_ci_failure_for[head_sha] ||= @job.workflows
      .where(trigger_kind: "ci_failure", state: "succeeded")
      .order(finished_at: :desc, id: :desc)
      .detect { |workflow| workflow.artifact("head_sha") == head_sha }
  end

  def record_no_effective_ci_repair!(head_sha, detail)
    workflow = latest_succeeded_ci_failure_for(head_sha)
    checks_state = detail[:any_failed?] ? "failing" : "pending"
    failed_checks = (detail[:failed_checks] || []).map do |check|
      check = check.to_h
      {
        "name" => check[:name] || check["name"],
        "conclusion" => check[:conclusion] || check["conclusion"],
        "html_url" => check[:html_url] || check["html_url"]
      }.compact
    end

    workflow.set_artifact!(
      "no_effective_ci_repair",
      {
        "head_sha" => head_sha,
        "checks_state" => checks_state,
        "failed_checks" => failed_checks,
        "detected_at" => Time.current.iso8601
      }
    )
    @job.update!(
      last_ci_handled_sha: nil,
      landing_failure_reason: "#{NO_EFFECTIVE_CI_REPAIR_REASON} on #{head_sha[0, 7]}"
    )
    Rails.logger.warn(
      "[PollPullRequestJob] #{@job.slug}: CI repair WF-#{workflow.id} made no effective change " \
      "for #{head_sha[0, 7]}; clearing last_ci_handled_sha"
    )
  end

  def no_effective_ci_repair_landing_reason?
    @job.landing_failure_reason.to_s.start_with?(NO_EFFECTIVE_CI_REPAIR_REASON)
  end

  def enrich_failed_check(check)
    CiRepair::CheckEnricher.call(check)
  end

end
