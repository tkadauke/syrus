module Mcp
  class ReadOnlyRepositoryLookup
    include McpToolPayloads::JobPayload

    BODY_EXCERPT_LENGTH = 2048
    DEFAULT_GITHUB_LIMIT = 20
    MAX_LIMIT = 100

    def self.from_server_context(server_context)
      new(McpToolContext.from_server_context(server_context))
    end

    def initialize(context)
      @context = context
    end

    def ensure_investigation_lookup_permitted
      return nil unless @context.run?
      return nil if McpToolPolicy.capability_permitted?(@context, :investigation_lookup)

      Mcp::Tools.not_authorized
    end

    def search_jobs(query:, state: nil, limit: 20)
      query = query.to_s.strip
      return Mcp::Tools.invalid("query must be at least 2 characters") if query.length < 2

      scope = job_scope
      scope = scope.where(state: state.to_s) if state.to_s.strip.present?
      scope = apply_search(scope, query)
      total = scope.count

      Mcp::Tools.success(
        total: total,
        results: scope
          .order(updated_at: :desc, id: :desc)
          .limit(normalize_limit(limit))
          .preload(:repository)
          .map { |job| job_search_payload(job) }
      )
    end

    def list_jobs(state: "open", label: nil, limit: 20)
      state = state.to_s.presence || "open"
      return Mcp::Tools.invalid("state must be open or closed") unless %w[open closed].include?(state)

      scope = job_scope.order(created_at: :desc, id: :desc)
      scope = state == "open" ? scope.open_threads : scope.closed_threads
      scope = apply_label_filter(scope, label)
      return scope if scope.is_a?(MCP::Tool::Response)

      Mcp::Tools.success(
        jobs: scope
          .limit(normalize_limit(limit))
          .preload(:repository)
          .map { |job| job_list_payload(job) }
      )
    end

    def list_pull_requests(state: "open", limit: DEFAULT_GITHUB_LIMIT)
      repository = repository_for_github_lookup
      return repository if repository.is_a?(MCP::Tool::Response)

      state = state.to_s.presence || "open"
      return Mcp::Tools.invalid("state must be open, closed, or merged") unless %w[open closed merged].include?(state)

      pull_requests = GithubClient
        .for(repository: repository, user: @context.user)
        .list_pull_requests_for_triage(
          repository.slug,
          state: state,
          limit: normalize_github_limit(limit)
        )

      Mcp::Tools.success(
        pull_requests: pull_requests.map { |pull_request| pull_request_payload(pull_request) }
      )
    rescue ArgumentError, Octokit::Error => e
      Mcp::Tools.invalid(e.message)
    end

    def list_issues(state: "open", label: nil, limit: DEFAULT_GITHUB_LIMIT)
      repository = repository_for_github_lookup
      return repository if repository.is_a?(MCP::Tool::Response)

      state = state.to_s.presence || "open"
      return Mcp::Tools.invalid("state must be open or closed") unless %w[open closed].include?(state)

      issues = GithubClient
        .for(repository: repository, user: @context.user)
        .list_issues_for_triage(
          repository.slug,
          state: state,
          label: label.to_s.presence,
          limit: normalize_github_limit(limit)
        )

      Mcp::Tools.success(
        issues: issues.map { |issue| issue_payload(issue) }
      )
    rescue ArgumentError, Octokit::Error => e
      Mcp::Tools.invalid(e.message)
    end

    def read_pull_request(pr_number:)
      repository = repository_for_github_lookup
      return repository if repository.is_a?(MCP::Tool::Response)

      pr_number = pr_number.to_i
      return Mcp::Tools.invalid("pr_number must be positive") unless pr_number.positive?

      client = GithubClient.for(repository: repository, user: @context.user)
      pr = client.pull_request(repository.slug, pr_number)
      diff = content_diff(repository, @context.user, pr) || client.pull_request_diff(repository.slug, pr_number)

      Mcp::Tools.success(
        pr: {
          number: pr.number,
          title: pr.title,
          body: pr.body.to_s,
          state: pr.state,
          html_url: pr.html_url,
          diff: Mcp::Tools.truncate_text(diff, Prompts::PullRequestSummary::MAX_DIFF_BYTES)
        }
      )
    rescue Octokit::NotFound
      Mcp::Tools.invalid("pull request not found: #{pr_number}")
    rescue ArgumentError, Octokit::Error => e
      Mcp::Tools.invalid(e.message)
    end

    private

    def job_scope
      if @context.run?
        run_repository_jobs
      elsif @context.user.admin?
        Job.all
      else
        Job.accessible_to(@context.user)
      end
    end

    def run_repository_jobs
      scope = @context.user.admin? ? Job.all : Job.accessible_to(@context.user)
      scope.where(repository_id: @context.repository&.id)
    end

    def repository_for_github_lookup
      repository = @context.repository
      return Mcp::Tools.invalid("repository context is required") unless repository
      return repository if @context.user.admin?
      return repository if Repository.accessible_to(@context.user).where(id: repository.id).exists?

      Mcp::Tools.not_authorized
    end

    def normalize_limit(value)
      value.to_i.clamp(1, MAX_LIMIT)
    end

    def normalize_github_limit(value)
      limit = value.to_i
      limit = DEFAULT_GITHUB_LIMIT unless limit.positive?
      [ limit, MAX_LIMIT ].min
    end

    def apply_search(scope, query)
      term = "%#{ActiveRecord::Base.sanitize_sql_like(query.downcase)}%"
      table = Job.arel_table
      columns = ([ "issue_title" ] + optional_search_columns).uniq
      predicate = columns
        .map { |column| Arel::Nodes::NamedFunction.new("LOWER", [ table[column] ]).matches(term) }
        .reduce { |combined, node| combined.or(node) }

      scope.where(predicate)
    end

    def optional_search_columns
      Job.column_names & %w[body description issue_body]
    end

    def apply_label_filter(scope, label)
      label = label.to_s.strip
      return scope if label.empty?
      return scope.where(skip_prepare: true) if label == Job::PREPARE_SKIP_LABEL

      Mcp::Tools.invalid("label filtering only supports #{Job::PREPARE_SKIP_LABEL.inspect} across user scope")
    end

    def pull_request_payload(pull_request)
      {
        number: pull_request.number,
        title: pull_request.title,
        head_ref: pull_request.head&.ref,
        base_ref: pull_request.base&.ref,
        mergeable: pull_request.mergeable,
        draft: pull_request.draft == true,
        created_at: pull_request.created_at&.iso8601,
        updated_at: pull_request.updated_at&.iso8601
      }
    end

    def issue_payload(issue)
      {
        number: issue.number,
        title: issue.title,
        labels: Array(issue.labels).map { |label| label.respond_to?(:name) ? label.name : label.to_s },
        state: issue.respond_to?(:state) ? issue.state : nil,
        author: issue.user&.login,
        created_at: issue.created_at&.iso8601,
        updated_at: issue.respond_to?(:updated_at) ? issue.updated_at&.iso8601 : nil,
        url: issue.respond_to?(:html_url) ? issue.html_url : nil,
        body_excerpt: issue.body.to_s.first(BODY_EXCERPT_LENGTH)
      }
    end

    # The PR's diff from repository content -- the git mirror when it has
    # both commits -- as unified diff text. nil when it cannot be read in
    # full (a commit the mirror lacks, GitHub's 300-file cap), so the caller
    # asks GitHub for the diff instead of showing part of one.
    def content_diff(repository, user, pr)
      base_sha = pr.respond_to?(:base) ? pr.base&.sha : nil
      head_sha = pr.respond_to?(:head) ? pr.head&.sha : nil
      return nil if base_sha.blank? || head_sha.blank?

      content = RepositoryContent.for(repository, user: user)
      changes = content.changes(base: content.resolve(base_sha), head: content.resolve(head_sha), patch: true)
      changes.map { |change| unified(change) }.join
    rescue RepositoryContent::Error
      nil
    end

    def unified(change)
      old_path = change.previous_path || change.path
      header = +"diff --git a/#{old_path} b/#{change.path}\n"
      header << "--- #{change.status == 'added' ? '/dev/null' : "a/#{old_path}"}\n"
      header << "+++ #{change.status == 'deleted' ? '/dev/null' : "b/#{change.path}"}\n"
      return header + "Binary files differ\n" if change.patch.nil? && change.status != "renamed"

      header + change.patch.to_s + (change.patch.to_s.end_with?("\n") || change.patch.nil? ? "" : "\n")
    end
  end
end
