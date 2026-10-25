require "mcp"

module SyrusRails
  class ExplainMigrationTool < MCP::Tool
    tool_name "explain_migration"

    description <<~DESC
      Execute newly added migrations against an isolated disposable database and return the
      requested migration's normalized before/after catalog. Falls back to a cumulative schema diff.
    DESC

    input_schema(
      type: "object",
      properties: {
        file_path: {
          type: "string",
          description: "Repository-relative migration path, e.g. db/migrate/20240101_add_name_to_users.rb or apps/shop/db/migrate/20240102_create_orders.rb"
        }
      },
      required: [ "file_path" ]
    )

    class << self
      def call(server_context:, file_path: nil)
        return McpToolSet.error_response("file_path is required") if file_path.to_s.strip.empty?

        workspace = McpToolSet.workspace_for(server_context)
        migration_path = workspace.join(file_path)
        return McpToolSet.error_response("Migration file not found: #{file_path}") unless migration_path.exist?

        run = SyrusMcp.run_from_context(server_context)
        result = MigrationArtifactGenerator.new(workspace: workspace, workflow: run.workflow).generate(file_path)
        McpToolSet.ok_response(result)
      rescue StandardError => e
        McpToolSet.error_response("#{e.class}: #{e.message}")
      end
    end
  end
end
