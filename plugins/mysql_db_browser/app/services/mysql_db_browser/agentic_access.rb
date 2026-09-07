module MysqlDbBrowser
  # Per-connection authorization for agent-issued (workflow/chat MCP tool)
  # access - the opposite of AdminMysql's global admin/repo check. Every
  # agentic tool call names a MysqlConnection id in its params, and this is
  # the single place that resolves it and enforces that connection's own
  # `agentic_access_enabled` flag (and, for writes, `allow_writes`) before any
  # tool touches the external database. There is no framework hook to do this
  # at manifest-build time (ChatToolSet/WorkflowToolSet#available_for? only
  # ever sees the surface, never an individual call's params) - so each tool
  # calls this from inside its own #call, mirroring
  # Mcp::Tools::AuthorizationSupport's find_*! pattern for first-party tools.
  # See Syrus::Plugin::AgenticConnection for the shared gating logic this
  # class and K8sCluster::AgenticAccess both delegate to.
  class AgenticAccess
    extend Syrus::Plugin::AgenticConnection

    class ConnectionNotFound < StandardError; end
    class AccessDisabled < StandardError; end
    class WriteAccessDisabled < StandardError; end

    RESOURCE_NAME = "MySQL connection"
    SETTINGS_LOCATION = "DB Browser connection settings"

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
      find_agentic!(
        MysqlConnection, id,
        resource_name: RESOURCE_NAME, settings_location: SETTINGS_LOCATION,
        not_found_error: ConnectionNotFound, access_disabled_error: AccessDisabled
      )
    end

    # Write gate for a connection QueryExecutor already resolved via
    # connection! - see Syrus::Plugin::AgenticConnection#require_write_access!
    # for why this takes the record itself rather than an id.
    def self.connection_with_write_access!(connection)
      require_write_access!(
        connection,
        resource_name: RESOURCE_NAME, settings_location: SETTINGS_LOCATION,
        write_access_disabled_error: WriteAccessDisabled
      )
    end
  end
end
