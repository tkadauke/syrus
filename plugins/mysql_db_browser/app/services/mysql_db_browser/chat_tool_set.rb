require "mcp"

module MysqlDbBrowser
  # Schema-browse and query-execution tools for workflow/chat agents,
  # gated per-connection rather than globally: availability only requires
  # the plugin to be enabled and at least one MysqlConnection to have opted
  # into agentic access, since the real authorization check (which specific
  # connection, per AgenticAccess) happens inside each tool's #call once the
  # agent names a mysql_connection_id.
  class ChatToolSet
    TOOL_CLASSES = [
      ListDatabasesTool,
      ListTablesTool,
      DescribeTableTool,
      ExecuteQueryTool
    ].freeze

    def self.available_for?(_chat_session, tier:)
      MysqlDbBrowser.enabled? && %i[essential deferred].include?(tier.to_sym) && MysqlConnection.where(agentic_access_enabled: true).exists?
    end

    def self.tool_definitions(tier:)
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
      return MCP::Tool::Response.new([ { type: "text", text: "Unknown MySQL DB Browser tool: #{tool_name.inspect}" } ], error: true) unless klass

      klass.call(**self.class.symbolize(params), server_context: server_context)
    rescue StandardError => e
      Rails.logger.error("[MysqlDbBrowser::ChatToolSet] #{e.class}: #{e.message}")
      MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
    end

    def self.symbolize(params)
      (params || {}).each_with_object({}) { |(key, value), normalized| normalized[key.to_sym] = value }
    end
  end
end
