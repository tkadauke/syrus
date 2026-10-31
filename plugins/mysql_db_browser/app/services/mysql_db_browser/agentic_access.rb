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

    def self.safe_connection_metadata(context:)
      connections = MysqlConnection.where(agentic_access_enabled: true).order(:label, :id).to_a
      connections.select! { |connection| coworker_connection_in_scope?(connection, context) }
      credentials_by_id = CredentialMaterial.credentials_by_id_for(connections)

      connections.filter_map do |connection|
        credential = credentials_by_id[connection.credential_store_credential_id]
        next unless usable_by?(connection, context, credential: credential)

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

    def self.connection!(id, context:, tool_name: nil)
      connection = MysqlConnection.find_by(id: id)
      credential = CredentialMaterial.credential_for(connection) if connection
      unless connection && usable_by?(connection, context, credential: credential)
        audit_coworker_refusal!(context: context, tool_name: tool_name)
        raise ConnectionNotFound, "#{RESOURCE_NAME} #{id.inspect} was not found."
      end
      unless coworker_connection_in_scope?(connection, context)
        audit_coworker_refusal!(context: context, tool_name: tool_name)
        raise ConnectionNotFound, "#{RESOURCE_NAME} #{id.inspect} was not found."
      end

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

    def self.usable_by?(connection, context, credential:)
      agentic_credential_usable_by?(connection.credential_store_credential_id, context, credential: credential)
    end

    def self.coworker_connection_in_scope?(connection, context)
      return true unless context&.role == AgentRole::COWORKER_CHAT

      context.capability_scopes["mysql.read"].to_s == connection.id.to_s
    end

    def self.audit_coworker_tool_call!(context:, tool_name:, success:, error_message: nil)
      return unless context&.role == AgentRole::COWORKER_CHAT

      connection = MysqlConnection.find_by(id: context.capability_scopes["mysql.read"])
      return unless connection

      QueryAudit.record_tool_call!(connection: connection, user: context.user, actor: context.agent_actor,
        tool_name: tool_name, success: success, error_message: error_message)
    end

    def self.audit_coworker_refusal!(context:, tool_name:)
      return if tool_name.blank?

      audit_coworker_tool_call!(context: context, tool_name: tool_name, success: false,
        error_message: "Rejected: MySQL connection was not found or is outside the coworker grant scope.")
    end
    private_class_method :audit_coworker_refusal!
  end
end
