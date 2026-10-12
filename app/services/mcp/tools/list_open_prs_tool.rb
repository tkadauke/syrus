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
        lookup = Mcp::ReadOnlyRepositoryLookup.from_server_context(server_context)
        denied = lookup.ensure_investigation_lookup_permitted
        return denied if denied

        lookup.list_pull_requests(state: state, limit: limit)
      end
    end
  end
end
