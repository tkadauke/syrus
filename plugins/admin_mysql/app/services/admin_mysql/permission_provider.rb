module AdminMysql
  class PermissionProvider
    include Syrus::Plugin::PermissionProvider

    ROLES = [ AgentRole::CHAT_PLANNER, AgentRole::WORKFLOW_IMPLEMENT ].freeze

    class << self
      def normalize_arguments(arguments)
        arguments.to_h.with_indifferent_access.slice(:limit, :thread_id).stringify_keys
      end

      def redact_arguments(arguments) = normalize_arguments(arguments)

      def fixed_classifier(operation, effects, risk)
        ->(_arguments) { { operation:, effects:, risk:, confidence: :certain } }
      end
    end

    register_resource_scope(
      :syrus_database,
      options: { fixed: true },
      normalize: ->(_scope, context:) { { "database" => "syrus" } },
      validate: ->(_scope, context:) { [] },
      label: ->(_scope, context:) { "This Syrus instance's database" },
      compare: ->(_left, _right, context:) { :equal }
    )

    register_capability(
      capability: "mysql.admin.observe@v1", operation: "mysql.admin/status@v1",
      effects: %i[confidential_read operational], risk: :medium,
      requestable_roles: ROLES, defaults: ROLES.index_with { :allow },
      maximum_autonomy: :job, authority_durations: %i[invocation chat_session job],
      resource_scope: :syrus_database,
      classifier: fixed_classifier("mysql.admin/status@v1", %i[confidential_read operational], :medium),
      fingerprint_normalizer: method(:normalize_arguments), redactor: method(:redact_arguments)
    )

    register_capability(
      capability: "mysql.admin.kill_query@v1", operation: "mysql.admin/kill_query@v1",
      effects: %i[external_write operational destructive], risk: :critical,
      requestable_roles: [ AgentRole::CHAT_PLANNER ], defaults: { AgentRole::CHAT_PLANNER => :ask },
      maximum_autonomy: :invocation, authority_durations: %i[invocation],
      resource_scope: :syrus_database,
      classifier: fixed_classifier("mysql.admin/kill_query@v1", %i[external_write operational destructive], :critical),
      fingerprint_normalizer: method(:normalize_arguments), redactor: method(:redact_arguments)
    )
  end
end
