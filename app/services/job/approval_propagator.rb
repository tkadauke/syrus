class Job::ApprovalPropagator
  Result = Data.define(:message, :status) do
    def success?
      status == :success
    end

    def failure?
      status == :failure
    end

    def skipped?
      status == :skipped
    end
  end

  def self.approve(job, user:)
    new(job, user:).approve
  end

  def self.dismiss(job, review_id, user:)
    new(job, user:).dismiss(review_id)
  end

  def initialize(job, user:)
    @job = job
    @user = user
  end

  def approve
    return skipped unless job.repository.approval_propagates_to_github
    return skipped if job.pr_number.blank?
    return skipped if pat_authored_pull_request?
    return skipped if app_authored_pull_request?

    review = client.create_pr_review(
      job.repository.slug,
      job.pr_number,
      event: "APPROVE",
      body: "Approved by @#{user.email_address} via Syrus."
    )
    review_id = review.respond_to?(:id) ? review.id : review[:id]
    job.approval_evidence = (job.approval_evidence || {}).merge("github_review_id" => review_id) if review_id
    job.save! if job.changed?
    Result.new(message: "GitHub review left.", status: :success)
  rescue Octokit::Error => e
    Rails.logger.warn("[Job::ApprovalPropagator] GitHub review failed for #{job.slug}: #{e.class}: #{e.message}")
    Result.new(message: "GitHub review failed: #{e.message}.", status: :failure)
  end

  # review_id is the review Syrus itself filed via #approve, when known.
  # It's blank whenever the PR's approval came from a raw GitHub review
  # left directly on github.com (never routed through #approve, so no id
  # was ever captured) — in that case, look up the PR's current reviews
  # and dismiss whichever one is APPROVED so it doesn't linger for the
  # next poll to re-read as a fresh approval signal.
  def dismiss(review_id)
    return skipped unless job.repository.approval_propagates_to_github
    return skipped if job.pr_number.blank?

    resolved_review_id = review_id.presence || approved_review_id
    return skipped if resolved_review_id.blank?

    client.dismiss_pr_review(job.repository.slug, job.pr_number, resolved_review_id, message: "Dismissed via Syrus.")
    Result.new(message: "GitHub review dismissed.", status: :success)
  rescue Octokit::Error => e
    Rails.logger.warn("[Job::ApprovalPropagator] GitHub dismiss failed for #{job.slug}: #{e.class}: #{e.message}")
    Result.new(message: "GitHub review dismiss failed: #{e.message}.", status: :failure)
  end

  private

  attr_reader :job, :user

  def client
    @client ||= GithubClient.for(repository: job.repository, user: user)
  end

  def app_authored_pull_request?
    return false unless job.repository.app_credential_active?

    app_slug = AppSetting.current.github_app_slug.to_s.presence
    return false unless app_slug

    pull_request = client.pull_request(job.repository.slug, job.pr_number, bypass_cache: true)
    pull_request.user&.login == "#{app_slug}[bot]"
  end

  def pat_authored_pull_request?
    job.credential_mode == "pat"
  end

  def approved_review_id
    reviews = client.pr_reviews(job.repository.slug, job.pr_number)
    approved = reviews.find { |review| review.state == "APPROVED" }
    return nil unless approved

    approved.respond_to?(:id) ? approved.id : approved[:id]
  end

  def skipped
    Result.new(message: nil, status: :skipped)
  end
end
