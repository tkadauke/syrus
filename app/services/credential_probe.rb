class CredentialProbe
  Result = Data.define(:credential, :ok, :message, :details) do
    def as_json(*)
      {
        credential: credential,
        ok: ok,
        message: message,
        details: details
      }
    end
  end

  TIMEOUT_SECONDS = 30
  MAX_OUTPUT_BYTES = 4_000
  REDACTED = "[redacted]".freeze
  CLASSIC_REPOSITORY_SCOPE_ALTERNATIVES = %w[repo public_repo].freeze

  def self.call(user:, credential:)
    new(user: user, credential: credential).call
  end

  def initialize(user:, credential:)
    @user = user
    @credential = credential.to_s
  end

  # Validate a GitHub token that has NOT been saved yet (the onboarding
  # paste-and-test flow). Returns a Result whose details carry the resolved
  # login, the token's OAuth scopes, and any `required_scopes` it is missing
  # so the UI can distinguish "invalid" from "valid but under-scoped".
  def self.github_token(token:, required_scopes: [], probe_repository: nil)
    token = token.to_s
    return Result.new(credential: "github_token", ok: false, message: "Paste a token to test it.", details: {}) if token.blank?

    client = Octokit::Client.new(
      access_token: token,
      user_agent: GithubClient::USER_AGENT,
      connection_options: GithubClient.connection_options
    )
    github_user = client.user
    headers = client.last_response&.headers || {}
    scopes = headers.fetch("x-oauth-scopes", "").to_s.split(",").map(&:strip).compact_blank
    required_scopes = required_scopes.map(&:to_s)
    fine_grained_pat = scopes.empty? && token.start_with?("github_pat_")
    missing = missing_required_scopes(required_scopes, scopes)

    if fine_grained_pat
      return fine_grained_repository_required(github_user, scopes) if probe_repository.blank?

      fine_grained_repository_probe(client, github_user, scopes, probe_repository.to_s.strip)
    elsif missing.any?
      label = missing.size == 1 ? "scope" : "scopes"
      Result.new(
        credential: "github_token",
        ok: false,
        message: "Token authenticated as #{github_user.login}, but it is missing the #{missing.join(" and ")} #{label}. " \
                 "Use a classic token with repo for private repositories or public_repo for public repositories; add workflow only if agents must edit GitHub Actions workflow files through the PAT. " \
                 "Or use a fine-grained token with repository Contents, Pull requests, and Workflows read/write plus Checks read.",
        details: { login: github_user.login, scopes: scopes, missing_scopes: missing }
      )
    else
      Result.new(
        credential: "github_token",
        ok: true,
        message: "Token is valid for #{github_user.login}.",
        details: { login: github_user.login, scopes: scopes, missing_scopes: [] }
      )
    end
  rescue Octokit::Unauthorized
    Result.new(credential: "github_token", ok: false, message: "GitHub rejected this token. Check that you copied the whole value.", details: {})
  rescue Octokit::Forbidden
    Result.new(credential: "github_token", ok: false, message: "GitHub accepted the token but refused to read your account. Check that the token has account read access, or paste a fine-grained token created for the repositories Syrus will manage.", details: {})
  rescue Octokit::Error
    Result.new(credential: "github_token", ok: false, message: "Could not reach GitHub to verify the token. Try again in a moment.", details: {})
  end

  def self.fine_grained_repository_required(github_user, scopes)
    Result.new(
      credential: "github_token",
      ok: false,
      message: "Fine-grained token authenticated as #{github_user.login}. Enter a repository slug so Syrus can verify repository write, GitHub Actions workflow-file access, and Checks read access before saving.",
      details: fine_grained_details(github_user.login, scopes).merge(needs_repository_probe: true)
    )
  end

  def self.fine_grained_repository_probe(client, github_user, scopes, repo_slug)
    unless repo_slug.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z})
      return Result.new(
        credential: "github_token",
        ok: false,
        message: "Enter the repository as owner/name so Syrus can verify fine-grained token access.",
        details: fine_grained_details(github_user.login, scopes).merge(needs_repository_probe: true)
      )
    end

    branch = "syrus-token-probe-#{SecureRandom.hex(8)}"
    branch_created = false
    repo = client.repository(repo_slug)
    base_ref = client.ref(repo_slug, "heads/#{repo.default_branch}")
    begin
      client.check_runs_for_ref(repo_slug, base_ref.object.sha)
    rescue Octokit::Forbidden
      return Result.new(
        credential: "github_token",
        ok: false,
        message: "Fine-grained token authenticated as #{github_user.login}, but GitHub refused the Checks read probe on #{repo_slug}. Grant Checks read for that repository.",
        details: fine_grained_details(github_user.login, scopes).merge(
          probed_repository: repo_slug,
          missing_repository_permissions: %w[checks:read]
        )
      )
    end

    client.create_ref(repo_slug, "refs/heads/#{branch}", base_ref.object.sha)
    branch_created = true
    client.create_contents(
      repo_slug,
      ".github/workflows/syrus-token-probe.yml",
      "Validate Syrus GitHub token workflow access",
      <<~YAML,
        name: Syrus token probe
        on:
          workflow_dispatch:
        jobs:
          probe:
            runs-on: ubuntu-latest
            steps:
              - run: echo "Syrus token probe"
      YAML
      branch: branch
    )

    Result.new(
      credential: "github_token",
      ok: true,
      message: "Fine-grained token can write workflow files and read Checks on #{repo_slug} as #{github_user.login}. Also grant Pull requests write; Syrus cannot verify it without creating a probe PR.",
      details: fine_grained_details(github_user.login, scopes).merge(
        probed_repository: repo_slug,
        workflow_file_write: true,
        checks_read: true,
        unverified_repository_permissions: %w[pull_requests:write]
      )
    )
  rescue Octokit::NotFound
    Result.new(
      credential: "github_token",
      ok: false,
      message: "Fine-grained token authenticated as #{github_user.login}, but #{repo_slug} was not accessible to it.",
      details: fine_grained_details(github_user.login, scopes).merge(probed_repository: repo_slug)
    )
  rescue Octokit::Forbidden
    Result.new(
      credential: "github_token",
      ok: false,
      message: "Fine-grained token authenticated as #{github_user.login}, but GitHub refused the workflow-file write probe on #{repo_slug}. Grant Contents and Workflows read/write for that repository.",
      details: fine_grained_details(github_user.login, scopes).merge(
        probed_repository: repo_slug,
        missing_repository_permissions: %w[contents:write workflows:write]
      )
    )
  ensure
    if branch_created
      begin
        client.delete_ref(repo_slug, "heads/#{branch}")
      rescue Octokit::Error => e
        Rails.logger.warn("[CredentialProbe] failed to delete GitHub token probe branch #{repo_slug}@#{branch}: #{e.class}: #{e.message}")
      end
    end
  end

  def self.fine_grained_details(login, scopes)
    {
      login: login,
      scopes: scopes,
      missing_scopes: [],
      fine_grained: true,
      required_repository_permissions: {
        contents: "write",
        pull_requests: "write",
        workflows: "write",
        checks: "read"
      }
    }
  end

  def self.missing_required_scopes(required_scopes, scopes)
    required_scopes.filter_map do |required_scope|
      next if required_scope == "repo" && (scopes & CLASSIC_REPOSITORY_SCOPE_ALTERNATIVES).any?
      next if scopes.include?(required_scope)

      required_scope
    end
  end

  private_class_method :fine_grained_repository_required, :fine_grained_repository_probe, :fine_grained_details, :missing_required_scopes

  CREDENTIAL_PROBE_METHODS = {
    "github_token"       => :probe_github
  }.freeze
  @registered_probe_handlers = {}
  @registered_secret_extractors = []

  # Both return the teardown that removes exactly this registration again, so
  # a disabled plugin stops contributing probes rather than leaving a handler
  # pointing at code that may no longer be loaded (see Syrus::Installer).
  # A handler may also expose `.key(key:) => Result` for the paste-and-test
  # flow, where the operator is validating a key they have not saved yet.
  # Optional: a credential with no such flow simply does not define it, and
  # `key_probe_for` answers nil.
  def self.key_probe_for(credential)
    handler = probe_handler_for(credential)
    return nil unless handler.respond_to?(:key)

    handler
  end

  def self.register_probe(credential, handler)
    key = credential.to_s
    previous = @registered_probe_handlers[key]
    @registered_probe_handlers[key] = handler

    -> { previous ? @registered_probe_handlers[key] = previous : @registered_probe_handlers.delete(key) }
  end

  def self.register_secret_extractor(extractor)
    return -> { } if @registered_secret_extractors.include?(extractor)

    @registered_secret_extractors << extractor
    -> { @registered_secret_extractors.delete(extractor) }
  end

  def self.probe_handler_for(credential)
    Syrus::Installer.sync!
    CREDENTIAL_PROBE_METHODS[credential.to_s] || @registered_probe_handlers[credential.to_s]
  end

  def call
    probe_handler = self.class.probe_handler_for(credential)
    raise ArgumentError, "Unknown credential: #{credential}" unless probe_handler

    probe_handler.is_a?(Symbol) ? send(probe_handler) : probe_handler.call(self)
  end

  private

  attr_reader :user, :credential

  def probe_github
    return missing("GitHub token is not configured.") if user.github_token.blank?

    client = Octokit::Client.new(
      access_token: user.github_token,
      user_agent: GithubClient::USER_AGENT,
      connection_options: GithubClient.connection_options
    )
    github_user = client.user
    headers = client.last_response&.headers || {}
    scopes = scopes_from(headers)

    Result.new(
      credential: credential,
      ok: true,
      message: "GitHub token is valid for #{github_user.login}.",
      details: {
        login: github_user.login,
        scopes: scopes,
        accepted_scopes: scopes_from(headers, "x-accepted-oauth-scopes")
      }
    )
  rescue Octokit::Unauthorized
    failure("GitHub rejected this token.")
  rescue Octokit::Forbidden => e
    failure("GitHub accepted the token but refused the probe: #{safe_error(e)}")
  rescue Octokit::Error => e
    failure("GitHub probe failed: #{safe_error(e)}")
  end

  def self.claude_cli_ready(user: nil)
    probe = new(user: user, credential: "claude_oauth_token")
    handler = probe_handler_for("claude_oauth_token")
    raise ArgumentError, "Unknown credential: claude_oauth_token" unless handler
    raise ArgumentError, "Credential probe does not support ambient CLI readiness: claude_oauth_token" unless handler.respond_to?(:cli_ready)

    handler.cli_ready(probe)
  end

  def success(credential, message)
    Result.new(credential: credential, ok: true, message: message, details: {})
  end

  def missing(message)
    Result.new(credential: credential, ok: false, message: message, details: {})
  end

  def wrong_mode(message)
    Result.new(credential: credential, ok: false, message: message, details: {})
  end

  def failure(message)
    Result.new(credential: credential, ok: false, message: message, details: {})
  end

  def append_output(output, chunk)
    output << chunk.to_s
    output.slice!(0, output.bytesize - MAX_OUTPUT_BYTES) if output.bytesize > MAX_OUTPUT_BYTES
  end

  def probe_failure_reason(result, output)
    return "timed out." if result.timed_out?
    return "stopped after no output." if result.silent_timed_out?
    return "process exited before completion." if result.aliveness_failed?

    sanitized = sanitize(output).presence
    sanitized || "process exited with status #{result.exit_status || "unknown"}."
  end

  def sanitize(value)
    text = value.to_s
    [
      user.github_token
    ].concat(registered_secrets).compact_blank.each do |secret|
      text = text.gsub(secret, REDACTED)
    end

    text.lines.map(&:strip).reject(&:blank?).last(3).join(" ").truncate(500)
  end

  def safe_error(error)
    sanitize(error.message)
  end

  def scopes_from(headers, key = "x-oauth-scopes")
    headers.fetch(key, "").to_s.split(",").map(&:strip).compact_blank
  end

  def registered_secrets
    Syrus::Installer.sync!
    self.class.instance_variable_get(:@registered_secret_extractors).flat_map { |extractor| Array(extractor.call(user)) }
  end
end
