require "json"
require "mcp"

module SyrusRails
  class McpToolSet
    include Syrus::Plugin::McpToolSet

    TOOL_DEFS = [
      {
        name:         "read_schema",
        description:  "Parse db/schema.rb and return structured JSON with tables, columns, indexes, and foreign keys. " \
                      "Call this when you need to understand the current database schema.",
        input_schema: { type: "object", properties: {}, required: [] }
      },
      {
        name:         "explain_migration",
        description:  "Parse a specific migration file and return before/after table state plus a change summary. " \
                      "Handles add_column, remove_column, rename_column, change_column, create_table, drop_table.",
        input_schema: {
          type:       "object",
          properties: {
            file_path: {
              type:        "string",
              description: "Relative path to the migration file, e.g. db/migrate/20240101_add_name_to_users.rb"
            }
          },
          required: ["file_path"]
        }
      },
      {
        name:         "list_routes",
        description:  "Parse config/routes.rb and return a structured list of HTTP routes. " \
                      "Best-effort; deep nesting is documented as approximate.",
        input_schema: { type: "object", properties: {}, required: [] }
      }
    ].freeze

    def self.available_for?(_repository)
      true
    end

    def self.tool_definitions
      TOOL_DEFS
    end

    def handle(tool_name, params, server_context)
      workspace = resolve_workspace(server_context)

      case tool_name
      when "read_schema"       then handle_read_schema(workspace)
      when "explain_migration" then handle_explain_migration(workspace, params[:file_path] || params["file_path"])
      when "list_routes"       then handle_list_routes(workspace)
      else
        error_response("Unknown Rails tool: #{tool_name.inspect}")
      end
    rescue StandardError => e
      error_response("#{e.class}: #{e.message}")
    end

    private

    def resolve_workspace(server_context)
      run = SyrusMcp.run_from_context(server_context)
      WorkflowWorkspace.path_for(run.workflow)
    end

    def handle_read_schema(workspace)
      schema_path = workspace.join("db", "schema.rb")
      return error_response("db/schema.rb not found in workspace") unless schema_path.exist?

      result = SchemaParser.parse(schema_path)
      ok_response(result)
    end

    def handle_explain_migration(workspace, file_path)
      return error_response("file_path is required") if file_path.to_s.strip.empty?

      migration_path = workspace.join(file_path)
      return error_response("Migration file not found: #{file_path}") unless migration_path.exist?

      schema_path = workspace.join("db", "schema.rb")
      result = MigrationParser.parse(migration_path, schema_path: schema_path.exist? ? schema_path : nil)
      ok_response(result)
    end

    def handle_list_routes(workspace)
      routes_path = workspace.join("config", "routes.rb")
      return error_response("config/routes.rb not found in workspace") unless routes_path.exist?

      result = RouteParser.parse(routes_path)
      ok_response(result)
    end

    def ok_response(data)
      MCP::Tool::Response.new([{ type: "text", text: JSON.generate(data) }])
    end

    def error_response(msg)
      MCP::Tool::Response.new([{ type: "text", text: "Error: #{msg}" }], error: true)
    end
  end
end
