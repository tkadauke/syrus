require "json"
require "mcp"

module SyrusRails
  class McpToolSet
    TOOL_CLASSES = [
      ReadSchemaTool,
      ExplainMigrationTool,
      ListRoutesTool
    ].freeze

    def self.available_for?(_repository)
      true
    end

    def self.tool_definitions
      TOOL_CLASSES.map do |klass|
        {
          name: klass.tool_name,
          description: klass.description_value,
          input_schema: klass.input_schema_value.to_h
        }
      end
    end

    def handle(tool_name, params, server_context)
      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      return self.class.error_response("Unknown Rails tool: #{tool_name.inspect}") unless klass

      klass.call(**self.class.symbolize(params), server_context: server_context)
    rescue StandardError => e
      self.class.error_response("#{e.class}: #{e.message}")
    end

    def self.workspace_for(server_context)
      run = SyrusMcp.run_from_context(server_context)
      WorkflowWorkspace.path_for(run.workflow)
    end

    def self.symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end

    def self.ok_response(data)
      MCP::Tool::Response.new([ { type: "text", text: JSON.generate(data) } ])
    end

    def self.error_response(msg)
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{msg}" } ], error: true)
    end
  end
end
