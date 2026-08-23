require "mcp"

module SyrusRails
  class ExplainMigrationTool < MCP::Tool
    tool_name "explain_migration"

    description <<~DESC
      Parse a specific migration file and return before/after table state plus a change summary.
      Handles add_column, remove_column, rename_column, change_column, create_table, drop_table.
    DESC

    input_schema(
      type: "object",
      properties: {
        file_path: {
          type: "string",
          description: "Relative path to the migration file, e.g. db/migrate/20240101_add_name_to_users.rb"
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

        schema_path = workspace.join("db", "schema.rb")
        result = MigrationParser.parse(migration_path, schema_path: schema_path.exist? ? schema_path : nil)
        McpToolSet.ok_response(result)
      rescue StandardError => e
        McpToolSet.error_response("#{e.class}: #{e.message}")
      end
    end
  end
end
