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
      handle_approval!(review_url: @pr.html_url, fork_pr_merged: true)
      return
    end

    return if @pr.state == "closed"  # closed without merge: no action

    check_for_review_approval
  end

  private

  def check_for_review_approval
    reviews = @client.pr_reviews(@job.repository.slug, @job.fork_review_pr_number)
    latest_approval = reviews
      .select { |review| review.state == "APPROVED" }
      .max_by { |review| review_submitted_at(review) || Time.at(0) }

    return unless latest_approval

    handle_approval!(
      review_url: latest_approval.respond_to?(:html_url) ? latest_approval.html_url : nil,
      fork_pr_merged: false
    )
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
