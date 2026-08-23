class GithubAuthenticatedGit
  AUTHENTICATED_GIT_FAILURE_PATTERN =
    /Invalid username or token|Authentication failed|could not read Username|terminal prompts disabled|repository not found/i.freeze

  def self.run(repository:, user:, git:, operation_type:, log: nil)
    new(repository: repository, user: user, git: git, operation_type: operation_type, log: log).run { |url| yield(url) }
  end

  def initialize(repository:, user:, git:, operation_type:, log: nil)
    @repository = repository
    @user = user
    @git = git
    @operation_type = operation_type
    @log = log
  end

  def run
    installation = GithubClient.active_installation_for(repository: repository, user: user)
    return yield default_url if installation.blank?

    refresh_attempted = false
    refresh_succeeded = false

    begin
      return yield app_url
    rescue GitRunner::GitError => original_error
      raise unless git_auth_failure?(original_error)

      refresh_attempted = true
      begin
        installation.invalidate_cached_token!
        result = yield app_url
        refresh_succeeded = true
        log&.call("github_auth: refreshed GitHub App installation token for #{repository.slug} #{operation_type}", kind: "system")
        return result
      rescue GitRunner::GitError => retry_error
        raise unless git_auth_failure?(retry_error)

        refresh_succeeded = true
        fallback_to_pat!(installation, retry_error, refresh_attempted: refresh_attempted, refresh_succeeded: refresh_succeeded) { |url| yield(url) }
      rescue Octokit::Unauthorized, Octokit::NotFound, Octokit::Error, ArgumentError => refresh_error
        fallback_to_pat!(installation, refresh_error, refresh_attempted: refresh_attempted, refresh_succeeded: refresh_succeeded) { |url| yield(url) }
      end
    rescue Octokit::Unauthorized, Octokit::NotFound, Octokit::Error, ArgumentError => original_error
      fallback_to_pat!(installation, original_error, refresh_attempted: refresh_attempted, refresh_succeeded: refresh_succeeded) { |url| yield(url) }
    end
  end

  private

  attr_reader :repository, :user, :git, :operation_type, :log

  def app_url
    installation = GithubClient.active_installation_for(repository: repository, user: user)
    raise ArgumentError, "GitHub App installation is not active" unless installation

    repository.authenticated_push_url(installation.fresh_token)
  end

  def default_url
    repository.authenticated_push_url(GithubClient.for(repository: repository, user: user).access_token)
  end

  def pat_url
    fallback_user = user || repository.user
    GithubClient.for_user(fallback_user, repository: repository)
    repository.authenticated_push_url(fallback_user.github_token)
  end

  def fallback_to_pat!(installation, error, refresh_attempted:, refresh_succeeded:)
    GithubAuthFallbackRecorder.record!(
      repository: repository,
      installation: installation,
      operation_type: operation_type,
      error: error,
      refresh_attempted: refresh_attempted,
      refresh_succeeded: refresh_succeeded
    )
    yield pat_url
  end

  def git_auth_failure?(error)
    text = "#{error.message}\n#{error.output}"
    text.match?(AUTHENTICATED_GIT_FAILURE_PATTERN)
  end
end
