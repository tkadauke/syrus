class PollExternalPrJob < ApplicationJob
  include GithubPrPollHelpers

  queue_as :polling

  # One concurrent poll per Job — prevents races on the closure write.
  limits_concurrency to: 1, key: ->(job_id, *) { "external_pr_poll:#{job_id}" }

  def perform(job_id)
    @job = Job.find_by(id: job_id)
    return unless @job&.open? && @job.external_pr_number.present?
    return if !@job.external_pr? && @job.pr_number.present?
    return if @job.repository.archived?

    @client = GithubClient.for(repository: @job.repository, user: @job.user)
    @slug = @job.repository.slug
    @pr = @client.pull_request(@slug, @job.external_pr_number)

    return close_with("external_pr_merged") if @pr.merged
    return close_with("external_pr_closed") if @pr.state == "closed"

    return unless @job.external_pr?

    react_to_pr_reviews
    ingest_pr_comments
  end

  private

  def close_with(reason)
    Rails.logger.info("[PollExternalPrJob] closing #{@job.slug}: #{reason}")
    @job.runs.active.find_each do |r|
      r.cancel! if r.may_cancel?
      r.save!
    end
    if reason == "external_pr_merged"
      sha = @pr.respond_to?(:merge_commit_sha) ? @pr.merge_commit_sha : @pr[:merge_commit_sha]
      @job.update_column(:landed_sha, sha) if sha.present?
    end
    @job.close_with_reason!(reason)
  end

  # ----- upstream PR review state ---------------------------------------
  # Mirrors PollPullRequestJob#react_to_pr_reviews / #react_to_review_state
  # / #react_to_pr_reviews_single for external_pr Jobs, which never have a
  # Syrus pr_number and so are invisible to PollPullRequestJob's own guard.

  def react_to_pr_reviews
    reviews = @client.pr_reviews(@slug, @job.external_pr_number)
    react_to_review_state(reviews)

    approvals = reviews.select { |review| review.state == "APPROVED" }
    return if approvals.empty?

    react_to_pr_reviews_single(approvals)
  end

  def react_to_review_state(reviews)
    if changes_requested?(reviews)
      @job.set_needs_attention!(reason: "upstream_pr_changes_requested")
    elsif @job.needs_attention_reason == "upstream_pr_changes_requested"
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

  def react_to_pr_reviews_single(approvals)
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

  # ----- comment ingestion -----------------------------------------------
  # Attribution + actionable classification via the same PrCommentIngester
  # pipeline PollPullRequestJob uses for Syrus-authored PRs. For fork Jobs
  # (Syrus cannot push to the branch), qualifying feedback puts the Job
  # into the same waiting state as a formal CHANGES_REQUESTED review — job
  # 3 of this Epic handles the same-repo fix-and-push reaction instead.

  def ingest_pr_comments
    cutoff = @job.last_seen_comment_at
    issue_comments = new_since(reject_syrus_bot_comments(@client.pr_issue_comments(@slug, @job.external_pr_number)), cutoff)
    review_comments = new_since(reject_syrus_bot_comments(@client.pr_review_comments(@slug, @job.external_pr_number)), cutoff)
    return if issue_comments.empty? && review_comments.empty?

    user = @job.owner_user || @job.user
    provider = @job.workflow_agent_provider

    issue_result = PrCommentIngester.call(
      job: @job, comments: issue_comments, pr_type: "external",
      comment_kind: "issue", user: user, agent_provider: provider
    )
    review_result = PrCommentIngester.call(
      job: @job, comments: review_comments, pr_type: "external",
      comment_kind: "review", user: user, agent_provider: provider
    )

    react_to_qualifying_feedback(issue_result, review_result) if @job.external_pr_fork?

    advance_comment_watermark(issue_comments + review_comments, cutoff)
  end

  def new_since(comments, cutoff)
    comments.select { |comment| cutoff.nil? || (comment.created_at && comment.created_at > cutoff) }
  end

  # `qualifying_records` (per PrCommentIngester#qualifies_for_workflow?)
  # already covers job_owner comments unconditionally, and member/external
  # comments when the repository's feedback_policy is "auto" — so a
  # qualifying record here is exactly the set the operator said should be
  # treated like a formal CHANGES_REQUESTED review, no distinction. External
  # comments that don't clear that bar (feedback_policy != "auto") aren't
  # auto-acted on; they're surfaced to the job owner as a notification
  # instead of pausing landing.
  def react_to_qualifying_feedback(issue_result, review_result)
    qualifying = issue_result.qualifying_records + review_result.qualifying_records
    non_qualifying = issue_result.non_qualifying_records + review_result.non_qualifying_records
    external_notify_records = non_qualifying.select { |record| record.actionable? && record.external? }

    return if qualifying.empty? && external_notify_records.empty?

    if qualifying.any?
      @job.set_needs_attention!(reason: "upstream_pr_changes_requested")
      unapprove_stale_approval!
    end

    external_notify_records.each { |record| notify_external_feedback(record) }
  end

  def unapprove_stale_approval!
    return unless @job.may_unapprove?

    Job::ApprovalUnapprover.call(job: @job, user: @job.user)
  end

  def notify_external_feedback(record)
    recipient = @job.owner_user || @job.user
    from = record.github_handle.present? ? "@#{record.github_handle}" : "an external contributor"
    body = "New feedback on #{@job.slug}'s external PR ##{@job.external_pr_number} from #{from}: " \
           "#{record.body.to_s.truncate(160)}"

    NotificationService.create_for(
      user: recipient,
      kind: "external_pr_feedback",
      job: @job,
      pr_url: App::Presentation.external_pr_url(@job),
      body: body
    )
  rescue => e
    Rails.logger.warn("[PollExternalPrJob] #{@job.slug}: could not send external_pr_feedback notification — #{e.message}")
  end

  def advance_comment_watermark(comments, cutoff)
    latest = comments.map(&:created_at).compact.max
    @job.update!(last_seen_comment_at: latest) if latest && (cutoff.nil? || latest > cutoff)
  end
end
