class PollForkReviewPrJob < ApplicationJob
  include GithubPrPollHelpers

  queue_as :default

  # One concurrent poll per Job — prevents concurrent approval handling.
  limits_concurrency to: 1, key: ->(job_id) { "fork_review_poll:#{job_id}" }

  def perform(job_id)
    @job = Job.find_by(id: job_id)
    return unless @job&.open? && @job.fork_review_pr_number.present?
    return if @job.pr_number.present?  # upstream PR already created; normal polling takes over
    return if @job.repository.archived?

    @client = GithubClient.for(repository: @job.repository, user: @job.user)
    @pr = @client.pull_request(@job.repository.slug, @job.fork_review_pr_number)

    # Accidental merge: the fork PR was merged on GitHub before Syrus detected an
    # approval signal. Treat the merge as the approval — skip the close step.
    if @pr.merged
      clear_fork_pr_closed_attention_if_set
      handle_approval!(review_url: @pr.html_url, fork_pr_merged: true)
      return
    end

    if @pr.state == "closed"
      handle_fork_pr_closed
      return
    end

    # PR is open — if we were in a grace period from a prior close, the
    # PR was reopened. Clear the alert and cancel the timer.
    if @job.needs_attention_reason == "fork_pr_closed"
      clear_fork_pr_closed_attention_if_set
    end

    check_for_review_approval
    react_to_fork_review_comments
  end

  private

  def handle_fork_pr_closed
    if @job.in_grace_period? && @job.needs_attention_reason == "fork_pr_closed"
      # Still in grace period and still closed — poll will retry next cycle.
      return
    end

    @job.set_needs_attention!(reason: "fork_pr_closed")
    return if @job.grace_period_expires_at.present?

    duration = @job.repository.fork_pr_grace_period_hours.hours
    @job.start_grace_period!(duration: duration)
    Rails.logger.info("[PollForkReviewPrJob] #{@job.slug}: fork PR closed without merge; grace period #{duration / 3600}h started")
  end

  def clear_fork_pr_closed_attention_if_set
    return unless @job.needs_attention_reason == "fork_pr_closed"

    @job.clear_needs_attention!
    @job.cancel_grace_period!
    Rails.logger.info("[PollForkReviewPrJob] #{@job.slug}: fork PR reopened or merged; cleared needs_attention")
  end

  def check_for_review_approval
    reviews = @client.pr_reviews(@job.repository.slug, @job.fork_review_pr_number)
    react_to_fork_review_state(reviews)

    # Block upstream PR if any reviewer's latest review is CHANGES_REQUESTED.
    return if changes_requested?(reviews)

    latest_approval = reviews
      .select { |review| review.state == "APPROVED" }
      .max_by { |review| review_submitted_at(review) || Time.at(0) }

    return unless latest_approval

    handle_approval!(
      review_url: latest_approval.respond_to?(:html_url) ? latest_approval.html_url : nil,
      reviewer_github_handle: latest_approval.user&.login,
      fork_pr_merged: false
    )
  end

  def react_to_fork_review_state(reviews)
    if changes_requested?(reviews)
      @job.set_needs_attention!(reason: "fork_pr_changes_requested")
    elsif @job.needs_attention_reason == "fork_pr_changes_requested"
      # All CHANGES_REQUESTED reviews are now APPROVED or DISMISSED.
      @job.clear_needs_attention!
    end
  end

  # Returns true if any reviewer's *latest* review on this PR is CHANGES_REQUESTED.
  def changes_requested?(reviews)
    latest_per_reviewer(reviews).any? { |review| review.state == "CHANGES_REQUESTED" }
  end

  # For each reviewer, return only their most-recent review.
  def latest_per_reviewer(reviews)
    reviews
      .group_by { |review| review.respond_to?(:user) ? review.user&.login : nil }
      .values
      .map { |reviewer_reviews| reviewer_reviews.max_by { |r| review_submitted_at(r) || Time.at(0) } }
      .compact
  end

  def handle_approval!(review_url:, reviewer_github_handle: nil, fork_pr_merged:)
    ForkReviewApprover.new(@job, fork_client: @client).call(
      review_url: review_url,
      reviewer_github_handle: reviewer_github_handle,
      fork_pr_merged: fork_pr_merged
    )
  end

  def react_to_fork_review_comments
    # Skip if check_for_review_approval just created the upstream PR —
    # the job will transition to normal polling via PollPullRequestJob.
    return if @job.reload.pr_number.present?
    return if pending_followup?

    cutoff = @job.last_seen_fork_review_comment_at
    all_comments = fetch_all_fork_review_comments
    new_comments = all_comments.select do |comment|
      cutoff.nil? || (comment.created_at && comment.created_at > cutoff)
    end
    return if new_comments.empty?

    ingestion = ingest_fork_review_comments(new_comments)
    return unless ingestion.any_qualifying?

    enqueue_fork_review_followup(
      all_comments: all_comments,
      new_comments: new_comments,
      qualifying_records: ingestion.qualifying_records
    )
  end

  def pending_followup?
    @job.workflows.active.where(trigger_kind: "pr_comment").exists?
  end

  def fetch_all_fork_review_comments
    slug = @job.repository.slug
    pr_number = @job.fork_review_pr_number
    issue_comments = @client.pr_issue_comments(slug, pr_number)
    review_comments = @client.pr_review_comments(slug, pr_number)
    reject_syrus_bot_comments(issue_comments + review_comments).sort_by(&:created_at)
  end

  def ingest_fork_review_comments(new_comments)
    issue_new = new_comments.reject { |c| c.respond_to?(:path) && c.path.present? }
    review_new = new_comments.select { |c| c.respond_to?(:path) && c.path.present? }

    user = @job.owner_user || @job.user
    provider = @job.agent_provider

    issue_result = PrCommentIngester.call(
      job: @job, comments: issue_new, pr_type: "fork_review",
      comment_kind: "issue", user: user, agent_provider: provider
    )
    review_result = PrCommentIngester.call(
      job: @job, comments: review_new, pr_type: "fork_review",
      comment_kind: "review", user: user, agent_provider: provider
    )

    PrCommentIngester::Result.new(
      qualifying_records: issue_result.qualifying_records + review_result.qualifying_records,
      non_qualifying_records: issue_result.non_qualifying_records + review_result.non_qualifying_records
    )
  end

  def enqueue_fork_review_followup(all_comments:, new_comments:, qualifying_records:)
    iteration = @job.workflows.where(trigger_kind: Workflow::TriggerKind.feedback_values).count + 1
    source_handle = qualifying_records.first&.github_handle

    artifacts = {
      "pr_comments" => all_comments.map { |c| serialize_comment(c) },
      "feedback_cutoff" => @job.last_seen_fork_review_comment_at&.iso8601,
      "pr_feedback_iteration" => iteration,
      "pr_feedback_auto" => true,
      "pr_feedback_source_handle" => source_handle,
      "pr_review_comment_ids" => qualifying_records.map(&:id)
    }
    workflow = Workflows::PrFeedback.instantiate(job: @job, artifacts: artifacts)
    StepDispatcher.start_workflow(workflow)

    qualifying_records.each { |r| r.mark_handling_started!(workflow: workflow, by: "auto_poll") }

    latest = new_comments.map(&:created_at).compact.max
    @job.update!(last_seen_fork_review_comment_at: latest) if latest
  end

end
