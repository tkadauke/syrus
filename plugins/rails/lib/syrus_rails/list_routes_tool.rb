require "mcp"

module SyrusRails
  class ListRoutesTool < MCP::Tool
    tool_name "list_routes"

    description <<~DESC
      Parse config/routes.rb and return a structured list of HTTP routes.
      Best-effort; deep nesting is documented as approximate.
    DESC

    input_schema(type: "object", properties: {}, required: [])

    class << self
      def call(server_context:)
        workspace = McpToolSet.workspace_for(server_context)
        routes_path = workspace.join("config", "routes.rb")
        return McpToolSet.error_response("config/routes.rb not found in workspace") unless routes_path.exist?

        McpToolSet.ok_response(RouteParser.parse(routes_path))
      rescue StandardError => e
        McpToolSet.error_response("#{e.class}: #{e.message}")
      end
    end
  end
end
