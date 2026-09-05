require "mcp"

module ScheduledTasks
  # The schedule tools a chat agent can reach.
  #
  # Each definition carries its own policy, which is what lets these leave
  # core without changing behaviour: the two that create or fire work stay out
  # of Supervisor chats, and the two read-only ones remain available to the
  # scoped-event evaluator, whose core set is a fixed allowlist.
  class ChatToolSet
    include Syrus::Plugin::ChatMcpToolSet

    TOOL_CLASSES = [
      McpTools::ScheduleRecurringTool,
      McpTools::ListScheduledTasksTool,
      McpTools::ReadScheduledTaskTool,
      McpTools::UpdateScheduledTaskTool,
      McpTools::PauseScheduledTaskTool,
      McpTools::ResumeScheduledTaskTool,
      McpTools::DeleteScheduledTaskTool,
      McpTools::FireScheduledTaskNowTool
    ].freeze

    SUPERVISOR_EXCLUDED = %w[schedule_recurring fire_scheduled_task_now].freeze
    EVALUATOR_TOOLS = %w[list_scheduled_tasks read_scheduled_task].freeze

    def self.available_for?(_chat_session, tier:)
      return false unless ScheduledTasks.enabled?

      %i[deferred evaluator].include?(tier.to_sym)
    end

    def self.tool_definitions(tier:)
      TOOL_CLASSES.map { |klass| definition_for(klass) }
    end

    def self.definition_for(klass)
      name = klass.tool_name
      {
        name: name,
        description: klass.description_value,
        input_schema: klass.input_schema_value.to_h,
        supervisor_excluded: SUPERVISOR_EXCLUDED.include?(name),
        evaluator: EVALUATOR_TOOLS.include?(name)
      }
    end

    def handle(tool_name, params, server_context)
      klass = TOOL_CLASSES.find { |candidate| candidate.tool_name == tool_name.to_s }
      unless klass
        return MCP::Tool::Response.new([ { type: "text", text: "Unknown scheduled task tool: #{tool_name.inspect}" } ], error: true)
      end

      klass.call(**self.class.symbolize(params), server_context: server_context)
    rescue StandardError => e
      Rails.logger.error("[ScheduledTasks::ChatToolSet] #{e.class}: #{e.message}")
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
    end

    def self.symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
