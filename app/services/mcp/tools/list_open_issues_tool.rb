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
        lookup = Mcp::ReadOnlyRepositoryLookup.from_server_context(server_context)
        denied = lookup.ensure_investigation_lookup_permitted
        return denied if denied

        lookup.list_issues(state: state, label: label, limit: limit)
      end
    end
  end
end
