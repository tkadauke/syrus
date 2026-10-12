require "mcp"

module Mcp::Tools
  class SearchJobsTool < MCP::Tool
    tool_name "search_jobs"

    description "Search Syrus Jobs across all the current user's repositories by title and stored body text."

    input_schema(
      properties: {
        query: { type: "string", description: "Search text. Minimum length 2." },
        state: { type: "string", description: "Optional exact Job state filter." },
        limit: { type: "integer", description: "Maximum Jobs to return. Defaults to 20, capped at 100." }
      },
      required: %w[query]
    )

    class << self
      def call(server_context:, query:, state: nil, limit: 20)
        lookup = Mcp::ReadOnlyRepositoryLookup.from_server_context(server_context)
        denied = lookup.ensure_investigation_lookup_permitted
        return denied if denied

        lookup.search_jobs(query: query, state: state, limit: limit)
      end
    end
  end
end
