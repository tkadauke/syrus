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
    Rails.logger.warn("[Job::ApprovalPropagator] GitHub review failed for Job #{job.id}: #{e.class}: #{e.message}")
    Result.new(message: "GitHub review failed: #{e.message}.", status: :failure)
  end

  def dismiss(review_id)
    return skipped if review_id.blank?
    return skipped unless job.repository.approval_propagates_to_github
    return skipped if job.pr_number.blank?

    client.dismiss_pr_review(job.repository.slug, job.pr_number, review_id, message: "Dismissed via Syrus.")
    Result.new(message: "GitHub review dismissed.", status: :success)
  rescue Octokit::Error => e
    Rails.logger.warn("[Job::ApprovalPropagator] GitHub dismiss failed for Job #{job.id}: #{e.class}: #{e.message}")
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

  def skipped
    Result.new(message: nil, status: :skipped)
  end
end
