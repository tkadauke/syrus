module MysqlDbBrowser
  class PermissionProvider
    include Syrus::Plugin::PermissionProvider

    ROLES = [ AgentRole::CHAT_PLANNER, AgentRole::WORKFLOW_IMPLEMENT ].freeze
    READ_DEFAULTS = ROLES.index_with { :ask }.freeze
    READ_DURATIONS = %i[invocation chat_session job].freeze

    class << self
      def connection_scope(kind)
        {
          options: { hierarchy: %w[mysql_connection_id database table] },
          lookup: method(:lookup_connection),
          normalize: ->(scope, context:) { normalize_scope(scope, kind:) },
          validate: ->(scope, context:) { validate_scope(scope, kind:) },
          label: method(:scope_label),
          compare: method(:compare_scopes)
        }
      end

      def lookup_connection(identifier, context:)
        connection = MysqlConnection.find_by(id: identifier)
        return unless connection&.agentic_access_enabled?

        credential = CredentialMaterial.credential_for(connection)
        connection if AgenticAccess.usable_by?(connection, context[:mcp_context], credential: credential)
      end

      def normalize_scope(scope, kind:)
        value = scope.to_h.stringify_keys.slice("mysql_connection_id", "database", "table")
        if value.key?("mysql_connection_id")
          value["mysql_connection_id"] = Integer(value["mysql_connection_id"], exception: false)
        end
        value["database"] = value["database"].to_s if value.key?("database")
        value["table"] = value["table"].to_s if value.key?("table")
        value["kind"] = kind.to_s
        value
      end

      def validate_scope(scope, kind:)
        errors = []
        errors << "mysql_connection_id must be an integer" if scope.key?("mysql_connection_id") && !scope["mysql_connection_id"].is_a?(Integer)
        errors << "database requires mysql_connection_id" if scope["database"].present? && !scope["mysql_connection_id"].is_a?(Integer)
        errors << "table requires database" if scope["table"].present? && scope["database"].blank?
        errors
      end

      def scope_label(scope, context:)
        return "All MySQL #{scope.fetch('kind')} targets" unless scope["mysql_connection_id"]

        connection = MysqlConnection.find_by(id: scope.fetch("mysql_connection_id"))
        [ connection&.label || "MySQL connection #{scope.fetch('mysql_connection_id')}", scope["database"], scope["table"] ].compact.join(" / ")
      end

      def compare_scopes(left, right, context:)
        return :equal if left == right
        return :broader unless left["mysql_connection_id"]
        return :narrower unless right["mysql_connection_id"]
        return :disjoint unless left["mysql_connection_id"] == right["mysql_connection_id"]

        left_path = [ left["database"], left["table"] ].compact
        right_path = [ right["database"], right["table"] ].compact
        return :broader if right_path.first(left_path.length) == left_path
        return :narrower if left_path.first(right_path.length) == right_path

        :disjoint
      end

      def normalize_arguments(arguments)
        source = arguments.to_h.with_indifferent_access
        source.slice(:mysql_connection_id, :database, :table, :limit).stringify_keys.tap do |value|
          value["sql"] = source[:sql].to_s.strip.gsub(/\s+/, " ") if source.key?(:sql)
        end
      end

      def redact_arguments(arguments)
        normalize_arguments(arguments).tap { |value| value["sql"] = "[REDACTED SQL]" if value.key?("sql") }
      end
    end

    %i[connection database table query schema administrative].each do |kind|
      register_resource_scope(kind, **connection_scope(kind))
    end

    READ_OPERATIONS = {
      "mysql.connection/list@v1" => :connection,
      "mysql.database/list@v1" => :database,
      "mysql.table/list@v1" => :table,
      "mysql.schema/read@v1" => :schema
    }.freeze

    READ_OPERATIONS.each do |operation, scope|
      register_capability(
        capability: "mysql.read@v1", operation:, effects: %i[network_read confidential_read credential_use],
        risk: :medium, requestable_roles: ROLES, defaults: READ_DEFAULTS,
        maximum_autonomy: :job, authority_durations: READ_DURATIONS, resource_scope: scope,
        classifier: ->(_arguments) { { operation:, effects: %i[network_read confidential_read credential_use], risk: :medium, confidence: :certain } },
        fingerprint_normalizer: method(:normalize_arguments), redactor: method(:redact_arguments)
      )
    end

    register_capability(
      capability: "mysql.query@v1", operation: "mysql.query/execute@v1",
      effects: %i[network_read confidential_read credential_use external_write privilege_change operational destructive irreversible],
      risk: :critical, requestable_roles: ROLES, defaults: READ_DEFAULTS,
      maximum_autonomy: :invocation, authority_durations: %i[invocation], resource_scope: :query,
      classifier: MysqlDbBrowser::QueryClassification,
      fingerprint_normalizer: method(:normalize_arguments), redactor: method(:redact_arguments)
    )

    register_permission_preset(
      name: "mysql_read_only", label: "MySQL read-only",
      description: "Ask before reading metadata or data from a selected MySQL target.",
      rules: READ_OPERATIONS.map do |operation, _scope|
        { capability: "mysql.read@v1", operation:, role: AgentRole::CHAT_PLANNER,
          policy: :ask, resource_scope: {}, constraints: {} }
      end
    )

    register_permission_preset(
      name: "mysql_query_operator", label: "MySQL query operator",
      description: "Ask for each query invocation against a selected MySQL target.",
      rules: [ {
        capability: "mysql.query@v1", operation: "mysql.query/execute@v1",
        role: AgentRole::CHAT_PLANNER, policy: :ask, resource_scope: {}, constraints: {}
      } ]
    )
  end
end
