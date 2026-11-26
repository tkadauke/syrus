require "mcp"

module ReviewPlanning
  # The workflow agent's `submit_review_plan` tool, offered only to the
  # review_plan step.
  class McpToolSet
    include Syrus::Host::McpToolSet

    TOOL_CLASSES = [ Tools::SubmitReviewPlanTool ].freeze

    def self.available_for?(_repository) = ReviewPlanning.enabled?

    def self.available_for_context?(context)
      ReviewPlanning.enabled? && context.run? && context.run&.step&.kind == "review_plan"
    end

    def self.tool_definitions(context: nil)
      return [] if context && !available_for_context?(context)

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
      return Syrus::Host::McpTools.invalid("Unknown review plan tool: #{tool_name.inspect}") unless klass

      klass.call(**self.class.symbolize(params), server_context: server_context)
    rescue StandardError => e
      Rails.logger.error("[ReviewPlanning::McpToolSet] #{e.class}: #{e.message}")
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
    end

    def self.symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
