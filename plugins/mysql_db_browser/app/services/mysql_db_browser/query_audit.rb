module MysqlDbBrowser
  class QueryAudit
    MAX_TEXT_BYTES = 65_535
    MAX_STATEMENT_BYTES = MAX_TEXT_BYTES
    MAX_ERROR_MESSAGE_BYTES = MAX_TEXT_BYTES
    PENDING_MESSAGE = "Execution pending".freeze

    def self.start!(connection:, user:, statement:, read_only: true)
      raise ArgumentError, "An acting user is required to audit MySQL access" unless user

      MysqlQueryAudit.create!(
        mysql_connection: connection,
        user: user,
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

    def self.truncate(value, max_bytes = MAX_STATEMENT_BYTES)
      return value if value.bytesize <= max_bytes

      value.safe_byteslice(0, max_bytes)
    end
    private_class_method :truncate
  end
end
