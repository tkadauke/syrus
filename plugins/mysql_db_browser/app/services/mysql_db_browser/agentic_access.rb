module MysqlDbBrowser
  # Per-connection authorization for agent-issued (workflow/chat MCP tool)
  # access - the opposite of AdminMysql's global admin/repo check. Every
  # agentic tool call names a MysqlConnection id in its params, and this is
  # the single place that resolves it and enforces that connection's own
  # `agentic_access_enabled` flag before any tool touches the external
  # database. There is no framework hook to do this at manifest-build time
  # (ChatToolSet/WorkflowToolSet#available_for? only ever sees the surface,
  # never an individual call's params) - so each tool calls this from inside
  # its own #call, mirroring Mcp::Tools::AuthorizationSupport's find_*!
  # pattern for first-party tools.
  class AgenticAccess
    class ConnectionNotFound < StandardError; end
    class AccessDisabled < StandardError; end

    SAFE_METADATA_FIELDS = %i[
      id
      label
      default_database
      agentic_access_enabled
      allow_writes
      created_at
      updated_at
    ].freeze

    def self.safe_connection_metadata
      MysqlConnection.order(:label, :id).map do |connection|
        {
          id: connection.id,
          label: connection.label,
          default_database: connection.default_database,
          agentic_access_enabled: connection.agentic_access_enabled,
          allow_writes: connection.allow_writes,
          created_at: connection.created_at.iso8601,
          updated_at: connection.updated_at.iso8601
        }.slice(*SAFE_METADATA_FIELDS)
      end
    end

    def self.connection!(id)
      connection = MysqlConnection.find_by(id: id)
      raise ConnectionNotFound, "MySQL connection #{id.inspect} was not found." unless connection
      unless connection.agentic_access_enabled?
        raise AccessDisabled, "Agentic access is disabled for the \"#{connection.label}\" connection. " \
          "An admin must enable it from DB Browser connection settings before agents can query it."
      end

      connection
    end
  end
end
