require "mcp"

module Mcp::Tools
  class ListJobsTool < MCP::Tool
    tool_name "list_jobs"

    description "List Syrus Jobs across all the current user's repositories from Syrus's database."

    input_schema(
      properties: {
        state: { type: "string", enum: %w[open closed], description: "Job state. Defaults to open." },
        label: { type: "string", description: "Optional persisted Syrus label filter." },
        limit: { type: "integer", description: "Maximum Jobs to return. Defaults to 20, capped at 100." }
      }
    )

    class << self
      def call(server_context:, state: "open", label: nil, limit: 20)
        lookup = Mcp::ReadOnlyRepositoryLookup.from_server_context(server_context)
        denied = lookup.ensure_investigation_lookup_permitted
        return denied if denied

        lookup.list_jobs(state: state, label: label, limit: limit)
      end
    end
  end
end
