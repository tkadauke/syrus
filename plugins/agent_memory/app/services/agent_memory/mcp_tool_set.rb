require "mcp"

module AgentMemory
  # Workflow-surface tools: an agent running a Step can read, write, search,
  # list, and delete the memories it is allowed to see.
  class McpToolSet
    TOOL_CLASSES = [
      Tools::ReadMemoryTool,
      Tools::WriteMemoryTool,
      Tools::DeleteMemoryTool,
      Tools::SearchMemoriesTool,
      Tools::ListMemoriesTool
    ].freeze

    # Chat gets the workflow set plus sharing controls and, for admins, the
    # audit history.
    CHAT_TOOL_CLASSES = {
      essential: [ Tools::WriteMemoryTool, Tools::ReadMemoryTool ].freeze,
      deferred: [
        Tools::SearchMemoriesTool,
        Tools::ListMemoriesTool,
        Tools::DeleteMemoryTool,
        Tools::PublishMemoryTool,
        Tools::UnpublishMemoryTool
      ].freeze
    }.freeze

    def self.available_for?(_repository) = AgentMemory.enabled?

    def self.tool_definitions(context: nil)
      TOOL_CLASSES.map { |klass| definition_for(klass) }
    end

    def self.definition_for(klass)
      {
        name: klass.tool_name,
        description: klass.description_value,
        input_schema: klass.input_schema_value.to_h
      }
    end

    def self.handler_classes = TOOL_CLASSES

    def handle(tool_name, params, server_context)
      klass = self.class.handler_classes.find { |candidate| candidate.tool_name == tool_name.to_s }
      unless klass
        return MCP::Tool::Response.new([ { type: "text", text: "Unknown Agent Memory tool: #{tool_name.inspect}" } ], error: true)
      end

      klass.call(**self.class.symbolize(params), server_context: server_context)
    rescue StandardError => e
      Rails.logger.error("[AgentMemory::McpToolSet] #{e.class}: #{e.message}")
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
    end

    def self.symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
