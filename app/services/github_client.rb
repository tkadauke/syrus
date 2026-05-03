class GithubClient
  USER_AGENT = "Syrus/0.1 (+https://github.com/tkadauke/syrus)".freeze

  def self.for(user)
    new(user)
  end

  def initialize(user)
    raise ArgumentError, "user must have a github_token" if user.github_token.blank?
    @user = user
    @client = Octokit::Client.new(
      access_token: user.github_token,
      user_agent: USER_AGENT,
      auto_paginate: true
    )
  end

  # Returns Sawyer::Resource enumerable. Includes pull_request items —
  # IngestPolicy filters those.
  def issues_with_label(repo_slug, label, state: "open")
    track_rate_limits { @client.list_issues(repo_slug, state: state, labels: label) }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited on #{repo_slug}: #{e.message}")
    raise
  end

  def create_pull_request(repo_slug, base:, head:, title:, body:)
    track_rate_limits { @client.create_pull_request(repo_slug, base, head, title, body) }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited on #{repo_slug}: #{e.message}")
    raise
  end

  # Closes a PR without merging. Used by the scheduled-task
  # pr_pileup_policy=replace path to retire the previous tick's PR
  # before opening this tick's. Octokit's update_pull_request takes
  # state: "closed" — same endpoint GitHub's web "Close pull request"
  # button uses.
  def close_pull_request(repo_slug, pr_number)
    @client.update_pull_request(repo_slug, pr_number, state: "closed")
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited closing #{repo_slug}##{pr_number}: #{e.message}")
    raise
  end

  def fetch_issue(repo_slug, number)
    track_rate_limits { @client.issue(repo_slug, number) }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited on #{repo_slug}##{number}: #{e.message}")
    raise
  end

  def pull_request(repo_slug, pr_number)
    track_rate_limits { @client.pull_request(repo_slug, pr_number) }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited on #{repo_slug} PR ##{pr_number}: #{e.message}")
    raise
  end

  # PR conversation-tab comments. GitHub's `since` filter is honored
  # server-side here.
  def pr_issue_comments(repo_slug, pr_number, since: nil)
    options = {}
    options[:since] = since.utc.iso8601 if since
    track_rate_limits { @client.issue_comments(repo_slug, pr_number, options) }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] rate-limited on #{repo_slug} PR ##{pr_number} issue_comments: #{e.message}")
    raise
  end

  # Inline (line-anchored) review comments. Octokit's pull_request_comments
  # endpoint doesn't accept `since`, so filter client-side.
  def pr_review_comments(repo_slug, pr_number, since: nil)
    comments = track_rate_limits { @client.pull_request_comments(repo_slug, pr_number) }
    return comments unless since
    comments.select { |c| c.created_at && c.created_at > since }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] rate-limited on #{repo_slug} PR ##{pr_number} review_comments: #{e.message}")
    raise
  end

  # The "Approve / Request changes / Comment" wrapper rows. Used to detect
  # APPROVED state as a soft-stop signal for the feedback loop.
  def pr_reviews(repo_slug, pr_number)
    track_rate_limits { @client.pull_request_reviews(repo_slug, pr_number) }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] rate-limited on #{repo_slug} PR ##{pr_number} reviews: #{e.message}")
    raise
  end

  # All check runs for a commit SHA whose conclusion is a "failed-ish"
  # state (failure, timed_out, action_required, cancelled). Returns an
  # array of { name:, conclusion:, summary:, html_url: } hashes — just
  # what Prompts::CiFailure needs. In-progress / queued / pending
  # checks are intentionally excluded; we only act on completed
  # failures so the agent isn't reacting to a half-finished run.
  FAILED_CONCLUSIONS = %w[failure timed_out action_required cancelled stale].freeze

  def failed_check_runs_for(repo_slug, sha)
    runs = track_rate_limits { @client.check_runs_for_ref(repo_slug, sha) }
    Array(runs.check_runs).select { |cr| cr.status == "completed" && FAILED_CONCLUSIONS.include?(cr.conclusion) }.map do |cr|
      {
        name: cr.name,
        conclusion: cr.conclusion,
        summary: cr.output&.summary,
        html_url: cr.html_url
      }
    end
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] rate-limited on #{repo_slug}@#{sha} check_runs: #{e.message}")
    raise
  end

  # Returns { number:, url: } of the first OPEN PR that claims to close
  # this issue ("Closes #N" / "Fixes #N" / "Resolves #N" in the body, or
  # the manual GitHub "Linked issues" UI), or nil if there isn't one.
  # Used by PollRepositoryJob to detect the case where a human (or a
  # prior Syrus run we lost track of) already opened a PR for the
  # issue — so we don't pile a duplicate Syrus PR on top of it.
  #
  # GraphQL is the right tool here: `closedByPullRequestsReferences`
  # is the authoritative reverse of "this PR closes #N", with no
  # false positives from prose mentions. `includeClosedPrs: false`
  # filters merged/closed PRs at the API layer.
  def linked_open_pr_for_issue(repo_slug, issue_number)
    owner, name = repo_slug.split("/", 2)
    query = <<~GQL
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          issue(number: $number) {
            closedByPullRequestsReferences(first: 5, includeClosedPrs: false) {
              nodes { number url state }
            }
          }
        }
      }
    GQL
    body = { query: query, variables: { owner: owner, name: name, number: issue_number } }
    result = track_rate_limits { @client.post("/graphql", body.to_json) }
    # Sawyer preserves the GraphQL camelCase keys verbatim — access via
    # method-missing on that name. dig with the symbol is the safest
    # null-tolerant traversal.
    nodes = result.to_h.dig(:data, :repository, :issue, :closedByPullRequestsReferences, :nodes)
    return nil unless nodes
    pr = nodes.find { |n| (n[:state] || n["state"]).to_s == "OPEN" }
    return nil unless pr
    { number: pr[:number] || pr["number"], url: pr[:url] || pr["url"] }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] rate-limited on #{repo_slug}##{issue_number} linked-PR lookup: #{e.message}")
    raise
  end

  # Returns { branches: [...names], default_branch: "main" } or raises.
  def repo_branches(repo_slug)
    repo     = track_rate_limits { @client.repo(repo_slug) }
    branches = track_rate_limits { @client.branches(repo_slug) }.map(&:name)
    { branches: branches, default_branch: repo.default_branch }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] rate-limited on #{repo_slug} branches: #{e.message}")
    raise
  end

  # Returns { user: "login", orgs: ["org1", "org2"] } — the authenticated
  # user's login plus all org logins they belong to, sorted.
  def accessible_owners
    login = track_rate_limits { @client.user }.login
    orgs  = track_rate_limits { @client.organizations }.map(&:login).sort
    { user: login, orgs: orgs }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited on accessible_owners: #{e.message}")
    raise
  end

  # Returns sorted repo names for the given owner. owner_type "user" fetches
  # the authenticated user's own repos; anything else fetches org repos.
  def owner_repos(owner, owner_type:)
    repos = if owner_type == "user"
      track_rate_limits { @client.repos(nil, type: "owner") }
    else
      track_rate_limits { @client.org_repos(owner) }
    end
    repos.map(&:name).sort
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited on #{owner} repos: #{e.message}")
    raise
  end

  private

  # Wraps an Octokit call. On success, persists the rate-limit headers the
  # response carries (every GitHub API response includes them for free). On
  # TooManyRequests, persists the headers from the error response and writes
  # a JobLog against the current run if one is active on this thread.
  def track_rate_limits
    result = yield
    persist_rate_limit_headers!(@client.last_response&.headers)
    result
  rescue Octokit::TooManyRequests => e
    persist_rate_limit_headers!(e.response_headers)
    write_rate_limit_job_log!(e.response_headers)
    raise
  end

  def persist_rate_limit_headers!(headers)
    return unless headers
    remaining = headers["x-ratelimit-remaining"]
    return unless remaining
    @user.update_columns(
      gh_rate_limit_remaining:  remaining.to_i,
      gh_rate_limit_limit:      headers["x-ratelimit-limit"].to_i,
      gh_rate_limit_reset_at:   Time.at(headers["x-ratelimit-reset"].to_i),
      gh_rate_limit_resource:   headers["x-ratelimit-resource"],
      gh_rate_limit_observed_at: Time.current
    )
  rescue => e
    Rails.logger.warn("[GithubClient] rate_limit persist failed: #{e.message}")
  end

  def write_rate_limit_job_log!(headers)
    run = Thread.current[:syrus_current_run]
    return unless run
    resource   = headers&.[]("x-ratelimit-resource") || "core"
    reset_epoch = headers&.[]("x-ratelimit-reset").to_i
    reset_str  = reset_epoch > 0 ? Time.at(reset_epoch).utc.strftime("%H:%M UTC") : "unknown"
    chunk      = "[rate-limited] #{resource} quota exhausted; resets #{reset_str}"
    next_seq   = (run.job_logs.maximum(:sequence) || -1) + 1
    run.job_logs.create!(chunk: chunk, sequence: next_seq, kind: "rate_limited")
  rescue => e
    Rails.logger.warn("[GithubClient] rate_limit log write failed: #{e.message}")
  end
end
