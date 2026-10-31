module MysqlDbBrowser
  class QueryAudit
    MAX_TEXT_BYTES = 65_535
    MAX_STATEMENT_BYTES = MAX_TEXT_BYTES
    MAX_ERROR_MESSAGE_BYTES = MAX_TEXT_BYTES
    PENDING_MESSAGE = "Execution pending".freeze
    TOOL_CALL_PREFIX = "MCP tool call".freeze

    def self.start!(connection:, user:, actor: nil, statement:, read_only: true)
      raise ArgumentError, "An acting user is required to audit MySQL access" unless user

      MysqlQueryAudit.create!(
        mysql_connection: connection,
        user: user,
        agent_actor_type: actor&.class&.polymorphic_name,
        agent_actor_id: actor&.id,
        statement: truncate(statement.to_s),
        read_only: read_only,
        success: false,
        error_message: PENDING_MESSAGE
      )
    end

    def self.succeed!(audit, row_count:, duration_ms:)
      audit.update!(success: true, row_count: row_count, error_message: nil, duration_ms: duration_ms)
    end

    def self.fail!(audit, error_message:, duration_ms: nil)
      audit.update!(success: false, error_message: truncate(error_message.to_s, MAX_ERROR_MESSAGE_BYTES), duration_ms: duration_ms)
    end

    def self.record_tool_call!(connection:, user:, actor:, tool_name:, success:, error_message: nil)
      audit = start!(
        connection: connection,
        user: user,
        actor: actor,
        statement: "/* #{TOOL_CALL_PREFIX}: #{tool_name} */",
        read_only: true
      )
      if success
        succeed!(audit, row_count: nil, duration_ms: 0)
      else
        fail!(audit, error_message: error_message)
      end
      audit
    end

    def self.truncate(value, max_bytes = MAX_STATEMENT_BYTES)
      return value if value.bytesize <= max_bytes

      value.safe_byteslice(0, max_bytes)
    end
    private_class_method :truncate
  end
end
