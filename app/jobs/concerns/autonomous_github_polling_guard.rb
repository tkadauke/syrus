module AutonomousGithubPollingGuard
  extend ActiveSupport::Concern

  private

  def autonomous_github_polling_rate_limited?(repository, user: nil, manual: false)
    return false if manual

    subject = github_polling_rate_limit_subject(repository, user: user)
    return false unless subject&.github_api_rate_limited?

    Rails.logger.info(
      "[#{self.class.name}] #{github_polling_repository_label(repository)} GitHub API rate limit exhausted; " \
      "skipping autonomous poll until #{subject.gh_rate_limit_reset_at&.utc&.iso8601 || "reset"}"
    )
    true
  end

  def handle_autonomous_github_polling_rate_limit(error, repository:, user: nil, manual: false)
    raise error if manual

    subject = github_polling_rate_limit_subject(repository, user: user)
    persist_github_polling_rate_limit!(subject, error) if subject

    Rails.logger.warn(
      "[#{self.class.name}] #{github_polling_repository_label(repository)} " \
      "GitHub API rate limit exhausted during autonomous poll: " \
      "#{error.class}: #{error.message}"
    )
  end

  def github_polling_rate_limit_subject(repository, user:)
    GithubClient.active_installation_for(repository: repository, user: user) || user || repository&.user
  end

  def persist_github_polling_rate_limit!(subject, error)
    headers = github_polling_error_headers(error)
    reset_at = github_polling_rate_limit_reset_at(headers) || 15.minutes.from_now
    attributes = {
      gh_rate_limit_remaining: 0,
      gh_rate_limit_limit: headers&.[]("x-ratelimit-limit")&.to_i,
      gh_rate_limit_reset_at: reset_at,
      gh_rate_limit_resource: headers&.[]("x-ratelimit-resource").presence || "core",
      gh_rate_limit_observed_at: Time.current
    }.compact

    subject.class.where(id: subject.id).update_all(attributes) # rubocop:disable Rails/SkipsModelValidations
    subject.assign_attributes(attributes)
    subject.mark_gh_api_blocked!(error.message) if subject.respond_to?(:mark_gh_api_blocked!)
  rescue => persist_error
    Rails.logger.warn("[#{self.class.name}] GitHub polling rate-limit persist failed: #{persist_error.message}")
  end

  def github_polling_error_headers(error)
    error.response_headers if error.respond_to?(:response_headers)
  rescue StandardError
    nil
  end

  def github_polling_rate_limit_reset_at(headers)
    reset_epoch = headers&.[]("x-ratelimit-reset").to_i
    Time.at(reset_epoch) if reset_epoch.positive?
  end

  def github_polling_repository_label(repository)
    repository&.slug || "repository"
  end
end
