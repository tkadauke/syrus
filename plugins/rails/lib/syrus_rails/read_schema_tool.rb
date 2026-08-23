require "mcp"

module SyrusRails
  class ReadSchemaTool < MCP::Tool
    tool_name "read_schema"

    description <<~DESC
      Parse db/schema.rb and return structured JSON with tables, columns, indexes, and foreign keys.
      Call this when you need to understand the current database schema.
    DESC

    input_schema(type: "object", properties: {}, required: [])

    class << self
      def call(server_context:)
        workspace = McpToolSet.workspace_for(server_context)
        schema_path = workspace.join("db", "schema.rb")
        return McpToolSet.error_response("db/schema.rb not found in workspace") unless schema_path.exist?

        McpToolSet.ok_response(SchemaParser.parse(schema_path))
      rescue StandardError => e
        McpToolSet.error_response("#{e.class}: #{e.message}")
      end
    end
  end
end
