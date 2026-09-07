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
    return skipped unless usable_credential?

    pr_author_login = fetch_pr_author_login
    return skipped if pr_author_login.blank?

    review_client = review_client_for(pr_author_login)
    return skipped if review_client.nil?

    review = review_client.create_pr_review(
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

  # Client used to read PR state (the author's login) regardless of which
  # identity ends up posting the review. Prefers the App installation,
  # falling back to the approving user's PAT — the same resolution every
  # other read path in the app uses.
  def client
    @client ||= GithubClient.for(repository: job.repository, user: user)
  end

  # Some usable credential must exist at all: either the approving user has
  # their own connected PAT, or the App has an active installation for this
  # repository. Without either, there is no identity that could ever post
  # the review.
  def usable_credential?
    user.github_token.present? || job.repository.app_credential_active?
  end

  def fetch_pr_author_login
    pull_request = client.pull_request(job.repository.slug, job.pr_number, bypass_cache: true)
    pull_request.user&.login
  end

  # A true GitHub self-review — the approving user's own login matches the
  # PR's author login — can only be posted by a *different* identity, so it
  # goes out via the App/bot's installation token. Every other case (a
  # different approver, or an approver with no connected PAT) posts as the
  # approving user's own PAT when possible so the review is genuinely
  # attributed to them; otherwise it falls back to the bot, same as before.
  def review_client_for(pr_author_login)
    approving_login = approving_user_login
    if approving_login.present? && approving_login != pr_author_login
      user_pat_client
    elsif job.repository.app_credential_active?
      GithubClient.for(repository: job.repository, user: nil)
    end
  end

  def user_pat_client
    return nil if user.github_token.blank?

    @user_pat_client ||= GithubClient.for_user(user, repository: job.repository)
  end

  def approving_user_login
    return @approving_user_login if defined?(@approving_user_login)

    @approving_user_login = begin
      user_pat_client&.authenticated_login
    rescue Octokit::Error => e
      Rails.logger.warn("[Job::ApprovalPropagator] could not resolve GitHub login for #{user.email_address}: #{e.class}: #{e.message}")
      nil
    end
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
