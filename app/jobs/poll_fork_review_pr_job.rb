class PollForkReviewPrJob < ApplicationJob
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

  def handle_approval!(review_url:, fork_pr_merged:)
    ForkReviewApprover.new(@job, fork_client: @client).call(
      review_url: review_url,
      fork_pr_merged: fork_pr_merged
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
end
