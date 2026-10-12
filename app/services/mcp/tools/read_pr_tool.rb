require "mcp"

module Mcp::Tools
  class ReadPrTool < MCP::Tool
    tool_name "read_pr"

    description "Read a GitHub pull request title, body, and capped diff for this chat session's repository."

    input_schema(
      properties: {
        pr_number: { type: "integer", description: "GitHub pull request number." }
      },
      required: %w[pr_number]
    )

    class << self
      def call(pr_number:, server_context:)
        lookup = Mcp::ReadOnlyRepositoryLookup.from_server_context(server_context)
        denied = lookup.ensure_investigation_lookup_permitted
        return denied if denied

        lookup.read_pull_request(pr_number: pr_number)
      end
    end
  end
end
