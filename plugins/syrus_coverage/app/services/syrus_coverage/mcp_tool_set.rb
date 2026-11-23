require "mcp"

module SyrusCoverage
  # Workflow agents' read access to the coverage artifact of the current Job's
  # most recent workflow, so an implementing agent can find under-tested files
  # before it writes tests.
  class McpToolSet
    TOOL_CLASSES = [ Tools::GetCoverageReportTool ].freeze

    def self.available_for?(_repository) = SyrusCoverage.enabled?

    def self.tool_definitions(context: nil)
      TOOL_CLASSES.map do |klass|
        {
          name: klass.tool_name,
          description: klass.description_value,
          input_schema: klass.input_schema_value.to_h,
          capability_descriptor: PermissionProvider.capability_descriptor(PermissionProvider::OPERATIONS.fetch(klass.tool_name))
        }
      end
    end

    def handle(tool_name, params, server_context)
      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      unless klass
        return MCP::Tool::Response.new([ { type: "text", text: "Unknown coverage tool: #{tool_name.inspect}" } ], error: true)
      end

      klass.call(**self.class.symbolize(params), server_context: server_context)
    rescue StandardError => e
      Rails.logger.error("[SyrusCoverage::McpToolSet] #{e.class}: #{e.message}")
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
    end

    def self.symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
