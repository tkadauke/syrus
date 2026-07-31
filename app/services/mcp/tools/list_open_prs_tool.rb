require "mcp"

module Mcp::Tools
  class ListOpenPrsTool < MCP::Tool
    DEFAULT_LIMIT = 20
    MAX_LIMIT = 100

    tool_name "list_open_prs"

    description <<~DESC
      List GitHub pull requests for this repository. Read-only. Returns PR
      metadata useful for triage, including refs, mergeability, draft state,
      creation time, and last update time.
    DESC

    input_schema(
      properties: {
        state: { type: "string", description: "Pull request state: open, closed, or merged. Defaults to open." },
        limit: { type: "integer", description: "Maximum PRs to return. Defaults to 20, max 100." }
      }
    )

    class << self
      def call(server_context:, state: "open", limit: DEFAULT_LIMIT)
        chat_session = server_context.fetch(:chat_session)
        state = state.to_s.presence || "open"
        return Mcp::Tools.invalid("state must be open, closed, or merged") unless %w[open closed merged].include?(state)

        pull_requests = GithubClient
          .for(repository: chat_session.repository, user: chat_session.user)
          .list_pull_requests_for_triage(
            chat_session.repository.slug,
            state: state,
            limit: normalize_limit(limit)
          )

        Mcp::Tools.success(
          pull_requests: pull_requests.map { |pull_request| pull_request_payload(pull_request) }
        )
      rescue ArgumentError, Octokit::Error => e
        Mcp::Tools.invalid(e.message)
      end

      private

      def normalize_limit(value)
        limit = value.to_i
        limit = DEFAULT_LIMIT unless limit.positive?
        [ limit, MAX_LIMIT ].min
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
    end
  end
end
