class GithubClient
  USER_AGENT = "Syrus/0.1 (+https://github.com/tkadauke/syrus)".freeze
  DELETE_BRANCH_TRANSIENT_RETRY_DELAYS = [ 0.5, 1.5 ].freeze

  # Faraday connection timeouts. Octokit (and Faraday underneath) has
  # NO default timeouts — a slow or stalled socket against GitHub will
  # block the worker thread forever. That happened in prod: 4
  # PollMergeStateJob threads wedged for 4+ hours on hanging
  # pull_request reads, locking the entire `default` queue (recurring
  # scheduler, app-event broadcasts, PR-feedback polling) behind them.
  #   open_timeout: TCP connect must complete in N seconds.
  #   timeout:      total request (incl. response read) capped at N.
  # Bound generously: GitHub's slowest documented endpoints (large
  # commit comparisons, etc.) finish well inside a minute when healthy.
  #
  # Octokit mutates the connection_options hash internally, so return
  # a fresh dup per call instead of freezing a constant.
  def self.connection_options
    { request: { open_timeout: 10, timeout: 30 } }
  end

  attr_reader :access_token

  def self.active_installation_for(repository:, user: nil)
    raise ArgumentError, "repository is required" unless repository

    membership_installation = user && repository.repository_memberships.find_by(user_id: user.id)&.installation
    installation = membership_installation || repository.installation
    installation if installation&.active?
  end

  def self.for(repository:, user: nil)
    raise ArgumentError, "repository is required" unless repository

    installation = active_installation_for(repository: repository, user: user)
    actor = user || repository.user

    if installation
      begin
        return new(repository: repository, user: actor, installation: installation, access_token: installation.fresh_token, auth_source: :installation)
      rescue Octokit::Unauthorized, Octokit::NotFound => e
        mark_installation_removed!(installation, e)
      end
    end

    for_user(actor, repository: repository)
  end

  def self.for_user(user, repository: nil)
    raise ArgumentError, "user must have a github_token" if user.blank? || user.github_token.blank?

    new(repository: repository, user: user, access_token: user.github_token, auth_source: :pat)
  end

  def self.mark_installation_removed!(installation, error)
    installation.update!(removed_at: Time.current) if installation.removed_at.blank?
    message = "[GithubClient] GitHub App installation #{installation.github_installation_id} for #{installation.account_login} detected as removed: #{error.class}: #{error.message}"
    Rails.logger.warn(message)
    if (run = Thread.current[:syrus_current_run])
      JobLog.append!(run: run, chunk: message, kind: "github_installation_removed")
    end
  rescue => e
    Rails.logger.warn("[GithubClient] installation removal audit failed: #{e.message}")
  end

  def initialize(user_arg = nil, user: nil, repository: nil, access_token: nil, installation: nil, auth_source: nil)
    user ||= user_arg
    if user && access_token.nil?
      raise ArgumentError, "user must have a github_token" if user.github_token.blank?
      access_token = user.github_token
      auth_source = :pat
    end
    raise ArgumentError, "GitHub token is required" if access_token.blank?

    @user = user
    @repository = repository
    @installation = installation
    @auth_source = auth_source || :pat
    @access_token = access_token
    @client = Octokit::Client.new(
      access_token: access_token,
      user_agent: USER_AGENT,
      auto_paginate: true,
      connection_options: self.class.connection_options,
      middleware: self.class.middleware_stack(cache_namespace)
    )
  end

  # Faraday middleware stack with conditional-request caching layered
  # on top of Octokit's defaults. ETag / Last-Modified / Cache-Control
  # are respected: a cache hit becomes an If-None-Match request, and
  # 304 Not Modified responses are served from cache without counting
  # against the GH rate limit. Cache is namespaced per user to keep
  # one user's authenticated view from leaking into another's.
  def self.middleware_stack(namespace)
    cache_store = ScopedCache.new(namespace)
    Faraday::RackBuilder.new do |builder|
      # HTTP cache must run BEFORE RaiseError so 304s are converted back
      # to cached 200s and never bubble up as exceptions.
      builder.use Faraday::HttpCache,
        store: cache_store,
        shared_cache: false,
        serializer: Marshal,
        logger: Rails.logger
      # Carry over Octokit's defaults verbatim: redirects, error
      # raising, GH feed parser. None of them take args today.
      Octokit::Default::MIDDLEWARE.handlers.each do |handler|
        builder.use handler.klass
      end
      builder.adapter Octokit::Default::MIDDLEWARE.adapter.klass
    end
  end

  # Wraps Rails.cache with a per-user key namespace so faraday-http-cache
  # entries from one user can't be served to another. Implements the
  # subset of the cache interface faraday-http-cache calls: read, write,
  # delete.
  class ScopedCache
    def initialize(namespace)
      @prefix = "github_etag/#{namespace}/".freeze
    end

    def read(key)
      Rails.cache.read(@prefix + key.to_s)
    end

    def write(key, value, opts = {})
      Rails.cache.write(@prefix + key.to_s, value, opts)
    end

    def delete(key)
      Rails.cache.delete(@prefix + key.to_s)
    end
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

  def open_pull_request_for_head(repo_slug, base:, head:)
    track_rate_limits { @client.pull_requests(repo_slug, state: "open", base: base, head: head).first }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited looking up #{repo_slug} PR #{head} -> #{base}: #{e.message}")
    raise
  end

  def create_issue(repo_slug, title:, body:, labels: [])
    track_rate_limits { @client.create_issue(repo_slug, title, body, labels: labels) }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited creating issue on #{repo_slug}: #{e.message}")
    raise
  end

  def readiness_check!
    track_rate_limits { @client.rate_limit }
    true
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

  # Deletes a branch ref. 422 (protected branch) and 404 (branch never
  # existed or already gone) are suppressed and logged as warnings —
  # GitHub may have auto-deleted the branch after merge. Octokit's
  # delete_branch uses boolean_from_response, which catches 404
  # internally and returns false; 422 raises Octokit::UnprocessableEntity.
  def delete_branch(repo_slug, branch_name)
    attempts = 0

    begin
      deleted = @client.delete_branch(repo_slug, branch_name)
      unless deleted
        Rails.logger.warn("[GithubClient] #{@user&.email_address} could not delete #{repo_slug}@#{branch_name} (branch not found or already deleted)")
        return false
      end

      true
    rescue Octokit::UnprocessableEntity => e
      Rails.logger.warn("[GithubClient] #{@user&.email_address} could not delete #{repo_slug}@#{branch_name} (suppressed): #{e.message}")
      false
    rescue Octokit::TooManyRequests => e
      Rails.logger.warn("[GithubClient] #{@user&.email_address} rate-limited deleting #{repo_slug}@#{branch_name} (suppressed): #{e.message}")
      false
    rescue Octokit::ServerError => e
      if attempts < DELETE_BRANCH_TRANSIENT_RETRY_DELAYS.length
        delay = DELETE_BRANCH_TRANSIENT_RETRY_DELAYS[attempts]
        attempts += 1
        Rails.logger.warn("[GithubClient] #{@user&.email_address} transient failure deleting #{repo_slug}@#{branch_name}: #{e.message}; retrying")
        sleep(delay) unless Rails.env.test?
        retry
      end

      Rails.logger.warn("[GithubClient] #{@user&.email_address} could not delete #{repo_slug}@#{branch_name} after transient GitHub failures (suppressed): #{e.message}")
      false
    end
  end

  def merge_pull_request(repo_slug, pr_number, commit_title:, merge_method:)
    track_rate_limits do
      @client.merge_pull_request(
        repo_slug,
        pr_number,
        "",
        commit_title: commit_title,
        merge_method: merge_method
      )
    end
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited merging #{repo_slug}##{pr_number}: #{e.message}")
    raise
  end

  def update_pull_request_body(repo_slug, pr_number, body)
    track_rate_limits { @client.update_pull_request(repo_slug, pr_number, body: body) }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited updating #{repo_slug}##{pr_number}: #{e.message}")
    raise
  end

  def update_pull_request_base(repo_slug, pr_number, base:)
    track_rate_limits { @client.update_pull_request(repo_slug, pr_number, base: base) }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited retargeting #{repo_slug}##{pr_number}: #{e.message}")
    raise
  end

  def fetch_issue(repo_slug, number)
    track_rate_limits { @client.issue(repo_slug, number) }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited on #{repo_slug}##{number}: #{e.message}")
    raise
  end

  def issue_comments(repo_slug, issue_number)
    track_rate_limits { @client.issue_comments(repo_slug, issue_number) }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited on #{repo_slug}##{issue_number} issue_comments: #{e.message}")
    raise
  end

  # `bypass_cache: true` reaches GitHub directly via a parallel
  # Octokit client that has no faraday-http-cache middleware. Used
  # by the on-demand "Check now" path: GitHub computes PR
  # mergeability lazily, and the conditional-GET 304 cycle can
  # serve stale `mergeable: true` for minutes after the value has
  # actually flipped on GitHub's side. Forcing a fresh body costs
  # one rate-limit token but is the only way to surface the new
  # value reliably. Periodic pollers stay on the cached path.
  def pull_request(repo_slug, pr_number, bypass_cache: false)
    client = -> { bypass_cache ? uncached_client : @client }
    track_rate_limits(response_client: client) { client.call.pull_request(repo_slug, pr_number) }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited on #{repo_slug} PR ##{pr_number}: #{e.message}")
    raise
  end

  def branch_head_sha(repo_slug, branch)
    client = -> { uncached_client }
    ref = track_rate_limits(response_client: client) { client.call.ref(repo_slug, "heads/#{branch}") }
    ref.object&.sha
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited fetching #{repo_slug}@#{branch}: #{e.message}")
    raise
  end

  def pull_request_diff(repo_slug, pr_number)
    track_rate_limits do
      @client.get(
        "repos/#{repo_slug}/pulls/#{pr_number}",
        accept: "application/vnd.github.v3.diff"
      ).to_s
    end
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited on #{repo_slug} PR ##{pr_number} diff: #{e.message}")
    raise
  end

  def repo_info(repo_slug, default_branch:)
    branches = track_rate_limits { @client.branches(repo_slug) }.map do |branch|
      {
        name: branch.name,
        sha: branch.commit&.sha
      }
    end

    commits = track_rate_limits do
      @client.get(
        "repos/#{repo_slug}/commits",
        sha: default_branch,
        per_page: 10
      )
    end.map do |commit|
      {
        sha: commit.sha,
        subject: commit.commit&.message.to_s.lines.first.to_s.strip
      }
    end

    {
      default_branch: default_branch,
      recent_commits: commits,
      branches: branches
    }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited inspecting #{repo_slug}: #{e.message}")
    raise
  end

  # Bare Octokit client — Octokit defaults only, NO faraday-http-cache.
  # Memoized so we don't rebuild the Faraday stack on every call. Same
  # token + user-agent as @client.
  def uncached_client
    @uncached_client ||= Octokit::Client.new(
      access_token: @access_token,
      user_agent: USER_AGENT,
      auto_paginate: true,
      connection_options: self.class.connection_options
    )
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

  # Files a PR review under whichever identity owns the token on this
  # client (operator's PAT or the GitHub App installation). Used by
  # Job::ApprovalPropagator to propagate Syrus-side approval onto the
  # PR so branch-protection rules requiring an approving review pass
  # at merge time. event is "APPROVE", "REQUEST_CHANGES", or "COMMENT".
  def create_pr_review(repo_slug, pr_number, event:, body: nil)
    track_rate_limits do
      @client.create_pull_request_review(
        repo_slug,
        pr_number,
        { event: event, body: body }.compact
      )
    end
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user&.email_address} rate-limited reviewing #{repo_slug}##{pr_number}: #{e.message}")
    raise
  end

  # Dismisses a previously-filed PR review (e.g. when the operator
  # unapproves in the Syrus UI). GitHub requires a dismissal message.
  def dismiss_pr_review(repo_slug, pr_number, review_id, message: "Dismissed by Syrus")
    track_rate_limits do
      @client.dismiss_pull_request_review(repo_slug, pr_number, review_id, message)
    end
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user&.email_address} rate-limited dismissing #{repo_slug}##{pr_number} review: #{e.message}")
    raise
  end

  def pr_commits(repo_slug, pr_number)
    track_rate_limits { @client.pull_request_commits(repo_slug, pr_number) }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] rate-limited on #{repo_slug} PR ##{pr_number} commits: #{e.message}")
    raise
  end

  # All check runs for a commit SHA whose conclusion is a "failed-ish"
  # state (failure, timed_out, action_required, cancelled). Returns an
  # array of { name:, conclusion:, summary:, log:, html_url: } hashes —
  # just what Prompts::CiFailure needs. In-progress / queued / pending
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
        log: cr.output&.text,
        html_url: cr.html_url
      }
    end
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] rate-limited on #{repo_slug}@#{sha} check_runs: #{e.message}")
    raise
  end

  # Summarizes check run state for a commit SHA. Returns a hash:
  #   { any?: bool, pending?: bool, any_failed?: bool, all_passed?: bool }
  # Used by PollMainBranchHealthJob to classify default-branch CI health.
  # "pending" means at least one check is still queued or in_progress.
  # "any_failed?" is true when any completed check has a FAILED_CONCLUSIONS value.
  # "all_passed?" is true when every check is completed with a passing conclusion.
  PASSING_CONCLUSIONS = %w[success neutral skipped].freeze

  def check_runs_summary_for(repo_slug, sha)
    runs = Array(track_rate_limits { @client.check_runs_for_ref(repo_slug, sha) }.check_runs)
    return { any?: false, pending?: false, any_failed?: false, all_passed?: false } if runs.empty?

    pending = runs.any? { |cr| cr.status != "completed" }
    any_failed = runs.any? { |cr| cr.status == "completed" && FAILED_CONCLUSIONS.include?(cr.conclusion) }
    all_passed = !pending && runs.all? { |cr| PASSING_CONCLUSIONS.include?(cr.conclusion) }

    { any?: true, pending?: pending, any_failed?: any_failed, all_passed?: all_passed }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] rate-limited on #{repo_slug}@#{sha} check_runs_summary: #{e.message}")
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

  # All open or closed issues for a repo (no label filter). Pull requests are
  # excluded — GitHub's issues endpoint returns them too when their state
  # matches. Results are sorted by updated_at desc (GitHub default).
  def list_all_issues(repo_slug, state: "open")
    track_rate_limits { @client.list_issues(repo_slug, state: state) }
      .reject { |i| i.respond_to?(:pull_request) && i.pull_request }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited listing issues on #{repo_slug}: #{e.message}")
    raise
  end

  def list_issues_for_triage(repo_slug, state: "open", label: nil, limit: 20)
    options = { state: state }
    options[:labels] = label if label.present?
    track_rate_limits { @client.list_issues(repo_slug, options) }
      .reject { |i| i.respond_to?(:pull_request) && i.pull_request }
      .first(limit)
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited listing triage issues on #{repo_slug}: #{e.message}")
    raise
  end

  def list_pull_requests_for_triage(repo_slug, state: "open", limit: 20)
    list_state = state == "merged" ? "closed" : state
    pulls = track_rate_limits { @client.pull_requests(repo_slug, state: list_state) }.first(limit)
    detailed_pulls = pulls.map do |pull|
      track_rate_limits { @client.pull_request(repo_slug, pull.number) }
    end

    case state
    when "merged"
      detailed_pulls.select { |pull| pull.merged_at.present? }
    when "closed"
      detailed_pulls.reject { |pull| pull.merged_at.present? }
    else
      detailed_pulls
    end
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited listing triage PRs on #{repo_slug}: #{e.message}")
    raise
  end

  def add_issue_comment(repo_slug, issue_number, body, on_behalf_of: nil)
    body = BotIdentity.prefix_comment(body, on_behalf_of: on_behalf_of)
    track_rate_limits { @client.add_comment(repo_slug, issue_number, body) }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited adding comment on #{repo_slug}##{issue_number}: #{e.message}")
    raise
  end

  def update_issue_comment(repo_slug, comment_id, body)
    track_rate_limits { @client.update_comment(repo_slug, comment_id, body) }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited updating comment #{comment_id} on #{repo_slug}: #{e.message}")
    raise
  end

  def close_issue(repo_slug, issue_number)
    track_rate_limits { @client.close_issue(repo_slug, issue_number) }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited closing #{repo_slug}##{issue_number}: #{e.message}")
    raise
  end

  def add_label_to_issue(repo_slug, issue_number, label)
    track_rate_limits { @client.add_labels_to_an_issue(repo_slug, issue_number, [ label ]) }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited adding label on #{repo_slug}##{issue_number}: #{e.message}")
    raise
  end

  # Returns sorted repo metadata for the given owner. owner_type "user" fetches
  # the authenticated user's own repos; anything else fetches org repos.
  def owner_repos(owner, owner_type:)
    repos = if owner_type == "user"
      track_rate_limits { @client.repos(nil, type: "owner") }
    else
      track_rate_limits { @client.org_repos(owner) }
    end
    repos.map { |repo|
      {
        name: repo.name,
        github_repository_id: repo.id,
        github_owner_id: repo.owner&.id
      }
    }.sort_by { |repo| repo[:name].to_s.downcase }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] #{@user.email_address} rate-limited on #{owner} repos: #{e.message}")
    raise
  end

  # Returns { commits: [...], merge_base_sha: "abc" } for commits that are
  # on `head` but not yet in `base`. Each commit entry has :sha, :short_sha,
  # :message (first line), and :date. Commits are returned newest-first.
  # Returns empty commits + nil merge_base_sha if the head branch doesn't
  # exist yet (Octokit::NotFound).
  def compare_commits(repo_slug, base, head)
    result = track_rate_limits { @client.compare(repo_slug, base, head) }
    commits = Array(result.commits).map { |c|
      {
        sha:       c.sha,
        short_sha: c.sha[0, 7],
        message:   c.commit.message.lines.first&.strip || "",
        date:      c.commit.committer.date
      }
    }.reverse
    { commits: commits, merge_base_sha: result.merge_base_commit.sha }
  rescue Octokit::NotFound
    { commits: [], merge_base_sha: nil }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] rate-limited on #{repo_slug} compare #{base}...#{head}: #{e.message}")
    raise
  end

  # Returns changed files for a GitHub compare. Patch may be nil for binary or
  # very large files.
  def compare_files(repo_slug, base, head)
    result = track_rate_limits { @client.compare(repo_slug, base, head) }
    files = Array(result.files).map { |file|
      {
        path: file.filename,
        status: file.status,
        additions: file.additions.to_i,
        deletions: file.deletions.to_i,
        patch: file.respond_to?(:patch) ? file.patch : nil
      }
    }
    { files: files, truncated: Array(result.files).size >= 300 }
  rescue Octokit::NotFound
    { files: [], truncated: false }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] rate-limited on #{repo_slug} compare #{base}...#{head}: #{e.message}")
    raise
  end

  # Returns { items: [...], truncated: bool } for all blob paths under `ref`.
  # Each item has :path and :size. Items are sorted alphabetically by path.
  # Fetches the commit's tree SHA first, then walks the tree recursively.
  def file_tree_at(repo_slug, ref)
    commit = track_rate_limits { @client.commit(repo_slug, ref) }
    tree   = track_rate_limits { @client.tree(repo_slug, commit.commit.tree.sha, recursive: 1) }
    items  = Array(tree.tree)
               .select { |item| item.type == "blob" }
               .map    { |item| { path: item.path, size: item.size.to_i } }
               .sort_by { |item| item[:path] }
    { items: items, truncated: tree.truncated == true }
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] rate-limited on #{repo_slug}@#{ref} tree: #{e.message}")
    raise
  end

  # Returns { content: "...", size: N } for the file at `path` at `ref`.
  # Returns nil if the path is not a blob (it's a directory or not found).
  # Content is decoded from base64 and transcoded to UTF-8; binary files
  # may contain replacement characters.
  def file_content_at(repo_slug, path, ref)
    result = track_rate_limits { @client.contents(repo_slug, path: path, ref: ref) }
    return nil unless result.respond_to?(:type) && result.type == "file"
    raw = Base64.decode64(result.content.to_s)
    { content: raw.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�"),
      size:    result.size.to_i }
  rescue Octokit::NotFound
    nil
  rescue Octokit::TooManyRequests => e
    Rails.logger.warn("[GithubClient] rate-limited on #{repo_slug}:#{path}@#{ref}: #{e.message}")
    raise
  end

  private

  # Wraps an Octokit call. On success, persists the rate-limit headers the
  # response carries (every GitHub API response includes them for free). On
  # TooManyRequests, persists the headers from the error response and writes
  # a JobLog against the current run if one is active on this thread.
  def track_rate_limits(response_client: -> { @client })
    result = yield
    persist_rate_limit_headers!(response_client.call.last_response&.headers)
    result
  rescue Octokit::Unauthorized, Octokit::NotFound => e
    raise unless installation_auth?
    handle_removed_installation!(e)
    result = yield
    persist_rate_limit_headers!(response_client.call.last_response&.headers)
    result
  rescue Octokit::TooManyRequests => e
    persist_rate_limit_headers!(e.response_headers)
    write_rate_limit_job_log!(e.response_headers)
    raise
  end

  def installation_auth?
    @auth_source == :installation && @installation.present?
  end

  def handle_removed_installation!(error)
    self.class.mark_installation_removed!(@installation, error)
    fallback_user = @user || @repository&.user
    raise ArgumentError, "GitHub App installation was removed and no fallback github_token is available" if fallback_user.blank? || fallback_user.github_token.blank?

    @auth_source = :pat
    @installation = nil
    @user = fallback_user
    @access_token = fallback_user.github_token
    @client = Octokit::Client.new(
      access_token: @access_token,
      user_agent: USER_AGENT,
      auto_paginate: true,
      connection_options: self.class.connection_options,
      middleware: self.class.middleware_stack(cache_namespace)
    )
    @uncached_client = nil
  end

  def cache_namespace
    installation_auth? ? "i#{@installation.id}" : "u#{@user.id}"
  end

  RATE_LIMIT_PERSIST_COALESCE = 30.seconds

  def persist_rate_limit_headers!(headers)
    return unless headers && @user
    remaining = headers["x-ratelimit-remaining"]
    return unless remaining

    remaining_i = remaining.to_i
    # Each GitHub API call triggers this writer through the Faraday
    # middleware, so multiple concurrent pollers race on the user row.
    # That contention used to bleed into the credentials-update path
    # in the request thread: the operator's UPDATE waited behind a
    # train of background writers and hit `innodb_lock_wait_timeout`.
    # Skip the write when the value hasn't moved AND we updated
    # recently — collapses "every API call" into "at most one row
    # update every 30s per user".
    if @user.gh_rate_limit_observed_at &&
       @user.gh_rate_limit_observed_at > RATE_LIMIT_PERSIST_COALESCE.ago &&
       @user.gh_rate_limit_remaining == remaining_i
      return
    end

    @user.update_columns(
      gh_rate_limit_remaining:  remaining_i,
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
    JobLog.append!(run: run, chunk: chunk, kind: "rate_limited")
  rescue => e
    Rails.logger.warn("[GithubClient] rate_limit log write failed: #{e.message}")
  end
end
