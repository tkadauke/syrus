class ExternalPrReviewRecovery
  SYRUS_GRADER_FAILURE_PREFIX = "Syrus ran the repository graders against this pull request and found failures:".freeze

  def self.call(job:, pr:, client:, reviews:)
    new(job:, pr:, client:, reviews:).call
  end

  def initialize(job:, pr:, client:, reviews:)
    @job = job
    @pr = pr
    @client = client
    @reviews = reviews
  end

  def call
    return false unless job.needs_attention_reason == Job::REQUESTED_CHANGES_ATTENTION_REASON
    return false unless current_head_checks_passing?

    changes_requested = latest_per_reviewer.select { |review| review_value(review, :state) == "CHANGES_REQUESTED" }
    return false if changes_requested.empty?

    syrus_reviews = changes_requested.select { |review| syrus_grader_failure_review?(review) }
    return false unless syrus_reviews.size == changes_requested.size

    syrus_reviews.each { |review| dismiss_review(review) }
    job.clear_needs_attention!
    LandingQueueProcessorJob.perform_later if job.approved? || job.landing?
    true
  end

  private

  attr_reader :job, :pr, :client, :reviews

  def current_head_checks_passing?
    head_sha = MergeabilityRecorder.head_sha(pr)
    head_sha.present? && job.pr_checks_sha == head_sha && job.pr_checks_state == "passing"
  end

  def latest_per_reviewer
    reviews
      .group_by { |review| review_value(review_value(review, :user), :login) }
      .values
      .map { |reviewer_reviews| reviewer_reviews.max_by { |review| review_submitted_at(review) || Time.at(0) } }
      .compact
  end

  def syrus_grader_failure_review?(review)
    syrus_authored_review?(review) && review_value(review, :body).to_s.start_with?(SYRUS_GRADER_FAILURE_PREFIX)
  end

  def syrus_authored_review?(review)
    syrus_bot_review?(review) || job_user_review?(review)
  end

  def syrus_bot_review?(review)
    user = review_value(review, :user)
    login = review_value(user, :login).to_s.strip.downcase
    type = review_value(user, :type).to_s.strip.downcase
    app_slug = AppSetting.current.github_app_slug.to_s.strip.downcase
    return false if login.blank? || app_slug.blank?

    bot_login = "#{app_slug.delete_suffix("[bot]")}[bot]"
    login == bot_login || (type == "bot" && login == app_slug)
  end

  def job_user_review?(review)
    expected_login = job.user&.github_handle.to_s.strip.downcase
    return false if expected_login.blank?

    user = review_value(review, :user)
    review_value(user, :login).to_s.strip.downcase == expected_login
  end

  def dismiss_review(review)
    review_id = review_value(review, :id)
    return if review_id.blank?

    client.dismiss_pr_review(
      job.repository.slug,
      job.external_pr_number,
      review_id,
      message: "Dismissed stale Syrus grader-failure review after current head checks passed."
    )
  rescue Octokit::Error => e
    Rails.logger.warn("[ExternalPrReviewRecovery] dismiss failed for #{job.slug} review #{review_id}: #{e.class}: #{e.message}")
  end

  def review_submitted_at(review)
    value = review_value(review, :submitted_at)
    return value if value.respond_to?(:to_time) && !value.is_a?(String)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  def review_value(resource, key)
    return unless resource
    return resource.public_send(key) if resource.respond_to?(key)
    if resource.respond_to?(:[]) && resource.respond_to?(:key?)
      return resource[key] if resource.key?(key)
      return resource[key.to_s] if resource.key?(key.to_s)
    end

    nil
  end
end
