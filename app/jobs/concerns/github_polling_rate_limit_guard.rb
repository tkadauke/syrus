module GithubPollingRateLimitGuard
  extend ActiveSupport::Concern

  DEFAULT_BACKOFF = 15.minutes
  RESET_BUFFER = 5.seconds

  private

  def github_polling_rate_limited?(repository, user:, manual: false, retry_args:, retry_kwargs: {}, label: self.class.name)
    return false if manual
    return false unless repository.github_api_rate_limited_for?(user: user)

    delay_github_poll_until_reset(repository, user: user, retry_args: retry_args, retry_kwargs: retry_kwargs, label: label)
    true
  end

  def with_github_polling_rate_limit_backoff(repository, user:, manual: false, retry_args:, retry_kwargs: {}, label: self.class.name)
    yield
  rescue Octokit::TooManyRequests => e
    raise if manual

    Rails.logger.warn("[#{label}] GitHub rate limit exhausted; delaying autonomous poll until reset: #{e.message}")
    delay_github_poll_until_reset(repository, user: user, retry_args: retry_args, retry_kwargs: retry_kwargs, label: label)
  end

  def delay_github_poll_until_reset(repository, user:, retry_args:, retry_kwargs:, label:)
    wait_until = github_polling_rate_limit_reset_at(repository, user: user)
    wait_until = wait_until.present? ? wait_until + RESET_BUFFER : DEFAULT_BACKOFF.from_now
    wait_until = 1.minute.from_now if wait_until <= Time.current

    Rails.logger.info("[#{label}] delaying autonomous poll until #{wait_until.utc.iso8601}")
    self.class.set(wait_until: wait_until).perform_later(*retry_args, **retry_kwargs)
  end

  def github_polling_rate_limit_reset_at(repository, user:)
    subject = GithubClient.active_installation_for(repository: repository, user: user) || user
    subject&.reload&.gh_rate_limit_reset_at
  rescue ActiveRecord::RecordNotFound
    nil
  end
end
