require "mcp"

module SyrusChatMcp
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
        state: { type: "string", enum: %w[open closed], description: "Issue state. Defaults to open." },
        label: { type: "string", description: "Optional GitHub label filter." },
        limit: { type: "integer", description: "Maximum issues to return. Defaults to 20, max 100." }
      }
    )

    class << self
      def call(server_context:, state: "open", label: nil, limit: DEFAULT_LIMIT)
        chat_session = server_context.fetch(:chat_session)
        state = state.to_s.presence || "open"
        return SyrusChatMcp.invalid("state must be open or closed") unless %w[open closed].include?(state)

        issues = GithubClient
          .for(repository: chat_session.repository, user: chat_session.user)
          .list_issues_for_triage(
            chat_session.repository.slug,
            state: state,
            label: label.to_s.presence,
            limit: normalize_limit(limit)
          )

        SyrusChatMcp.success(
          issues: issues.map { |issue| issue_payload(issue) }
        )
      rescue ArgumentError, Octokit::Error => e
        SyrusChatMcp.invalid(e.message)
      end

      private

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
          author: issue.user&.login,
          created_at: issue.created_at&.iso8601,
          body_excerpt: issue.body.to_s.first(BODY_EXCERPT_LENGTH)
        }
      end
    end
  end
end
