module FailureProblems
  # Classifies one failed GitHub API call from Octokit's own error class and
  # HTTP status -- the structure Octokit::Error.from_response already parsed.
  #
  # Kept apart from provider_transient on purpose: that code feeds the agent
  # provider circuit breaker, and a GitHub outage says nothing about whether
  # Claude or Codex is healthy.
  module GithubApi
    module_function

    # Raised for 5xx by Octokit::Error.from_response. 504 (and any other 5xx
    # without a dedicated class) arrives as the bare Octokit::ServerError.
    def for(error)
      status = response_status(error)
      base = { http_status: status, error_class: error.class.name }

      return FailureProblems.declare(:github_api_rate_limited, base) if rate_limited?(error, status)
      return FailureProblems.declare(:github_api_transient, base) if server_error?(error, status)
      return FailureProblems.declare(:pr_open_no_commits_between, base) if no_commits_between?(error)
      return FailureProblems.declare(:github_api_rejected, base) if client_error?(error, status)

      nil
    end

    # A request to GitHub that never got a response: the connection could not
    # be opened, was reset, or timed out. Octokit lets Faraday's exception
    # escape as-is, so it carries no status -- only a message naming the
    # host. Transient for GitHub hosts; any other host makes no claim.
    CONNECTION_ERRORS = [ Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError ].freeze
    GITHUB_HOST_PATTERN = /\b(?:api\.)?github\.com\b|\bgithubusercontent\.com\b/i

    def for_connection(error)
      return nil unless github_host?(error.message)

      FailureProblems.declare(:github_api_transient, error_class: error.class.name, connection_error: error.message.to_s.truncate(200))
    end

    def github_host?(message)
      message.to_s.match?(GITHUB_HOST_PATTERN)
    end

    def response_status(error)
      error.respond_to?(:response_status) ? error.response_status : nil
    end

    # Primary and secondary rate limits arrive as 403 bodies Octokit turns
    # into TooManyRequests / AbuseDetected; a plain 429 has no dedicated class.
    def rate_limited?(error, status)
      error.is_a?(Octokit::TooManyRequests) || error.is_a?(Octokit::AbuseDetected) || status.to_i == 429
    end

    def server_error?(error, status)
      error.is_a?(Octokit::ServerError) || status.to_i.between?(500, 599)
    end

    # GitHub refuses a PR whose head has no commits against its base. That is
    # retryable from the last mutation checkpoint (Problem::Kind), unlike
    # every other 422.
    def no_commits_between?(error)
      error.is_a?(Octokit::UnprocessableEntity) && error.message.to_s.match?(/No commits between/i)
    end

    # 404, 422, 409 and the like: GitHub understood the request and said no.
    # The same request gets the same answer.
    def client_error?(error, status)
      error.is_a?(Octokit::ClientError) || status.to_i.between?(400, 499)
    end
  end
end
