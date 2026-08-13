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

    react_to_pr_reviews if @job.external_pr?
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
end
