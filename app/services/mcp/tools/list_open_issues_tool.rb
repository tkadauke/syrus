require "mcp"

module Mcp::Tools
  class ListOpenIssuesTool < MCP::Tool
    BODY_EXCERPT_LENGTH = 2048
    DEFAULT_LIMIT = 20
    MAX_LIMIT = 100

    tool_name "list_open_issues"

    description <<~DESC
      List GitHub issues for this repository. Read-only. Returns issue
      metadata, labels, author, creation time, and the first ~2 KB of body.
    DESC

    input_schema(
      properties: {
        state: { type: "string", description: "Issue state: open or closed. Defaults to open." },
        label: { type: "string", description: "Optional GitHub label filter." },
        limit: { type: "integer", description: "Maximum issues to return. Defaults to 20, max 100." }
      }
    )

    class << self
      def call(server_context:, state: "open", label: nil, limit: DEFAULT_LIMIT)
        context = McpToolContext.from_server_context(server_context)
        repository = repository_for(context)
        return repository if repository.is_a?(MCP::Tool::Response)
        state = state.to_s.presence || "open"
        return Mcp::Tools.invalid("state must be open or closed") unless %w[open closed].include?(state)

        issues = GithubClient
          .for(repository: repository, user: context.user)
          .list_issues_for_triage(
            repository.slug,
            state: state,
            label: label.to_s.presence,
            limit: normalize_limit(limit)
          )

        Mcp::Tools.success(
          issues: issues.map { |issue| issue_payload(issue) }
        )
      rescue ArgumentError, Octokit::Error => e
        Mcp::Tools.invalid(e.message)
      end

      private

      def repository_for(context)
        repository = context.repository
        return Mcp::Tools.invalid("repository context is required") unless repository
        return repository unless context.run?
        return repository if context.allowed_repository_ids.include?(repository.id)

        Mcp::Tools.not_authorized
      end

      def normalize_limit(value)
        limit = value.to_i
        limit = DEFAULT_LIMIT unless limit.positive?
        [ limit, MAX_LIMIT ].min
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
    end
  end
end
