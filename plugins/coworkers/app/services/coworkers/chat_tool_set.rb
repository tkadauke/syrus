module Coworkers
  class ChatToolSet
    include Syrus::Plugin::ChatMcpToolSet

    TOOLS = [
      McpTools::ListCoworkersTool,
      McpTools::ReadCoworkerTool,
      McpTools::ProposeCoworkerTool,
      McpTools::ProposeGrantEscalationTool
    ].freeze
    WORKSPACE_TOOLS = [
      WorkspaceFileTools::Write,
      WorkspaceFileTools::Edit,
      WorkspaceFileTools::Move,
      WorkspaceFileTools::Delete
    ].freeze
    TOOL_CLASSES = ([ MessageCoworkerTool, ManageScheduleTool ] + WORKSPACE_TOOLS).freeze

    def self.available_for?(chat_session, tier:)
      Coworkers.enabled? && tier.to_sym == :deferred && !Coworkers::Chat.exists?(chat_session_id: chat_session.id)
    end

    def self.available_for_coworker?(_chat_session, tier:)
      Coworkers.enabled? && tier.to_sym == :essential
    end

    def self.tool_definitions(tier:)
      if tier.nil? || tier.to_sym == :essential
        return TOOL_CLASSES.map do |klass|
          workspace_tool = WORKSPACE_TOOLS.include?(klass)
          {
            name: klass.tool_name,
            description: klass.description_value,
            input_schema: klass.input_schema_value.to_h,
            coworker_safe: true,
            capability: if workspace_tool
              "workspace.files"
                        elsif klass == ManageScheduleTool
              "schedule.manage_self"
                        else
              "coworker.message"
                        end,
            coworker_grantless: workspace_tool,
            mutation: true
          }
        end
      end

      return [] unless tier.to_sym == :deferred

      TOOLS.map { |tool| { name: tool.tool_name, description: tool.description_value, input_schema: tool.input_schema_value.to_h } }
    end

    def handle(tool_name, params, server_context)
      tool = TOOLS.find { |candidate| candidate.tool_name == tool_name.to_s }
      return tool.call(**(params || {}).symbolize_keys, server_context: server_context) if tool

      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      return Mcp::Tools.invalid("Unknown coworker tool: #{tool_name.inspect}") unless klass

      klass.call(**symbolize(params), server_context: server_context)
    end

    private

    def symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
