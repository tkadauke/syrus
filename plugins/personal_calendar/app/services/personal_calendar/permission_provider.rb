module PersonalCalendar
  class PermissionProvider
    include Syrus::Host::PermissionProvider
    ROLES = [ Syrus::Host::AgentRole::CHAT_PLANNER, Syrus::Host::AgentRole::WORKFLOW_IMPLEMENT, Syrus::Host::AgentRole::COWORKER_CHAT, Syrus::Host::AgentRole::COWORKER ].freeze
    OPERATIONS = { "personal_calendar_list_events" => "personal_calendar.events/list@v1", "personal_calendar_get_event" => "personal_calendar.event/read@v1" }.freeze
    class << self
      def normalize_scope(scope, context:) = ConnectedAccounts::PermissionProvider.normalize_scope(scope, context:)
      def validate_scope(scope, context:) = ConnectedAccounts::PermissionProvider.validate_scope(scope, context:)
      def scope_label(scope, context:) = ConnectedAccounts::PermissionProvider.scope_label(scope, context:)
      def compare_scopes(left, right, context:) = ConnectedAccounts::PermissionProvider.compare_scopes(left, right, context:)
    end
    register_resource_scope :connected_account,
      options: { fields: [ { name: "account_id", type: "integer" }, { name: "acting_mode", type: "string" } ] },
      lookup: ConnectedAccounts::PermissionProvider.method(:lookup_account), normalize: method(:normalize_scope),
      validate: method(:validate_scope), label: method(:scope_label), compare: method(:compare_scopes)
    OPERATIONS.each_value do |operation|
      register_capability capability: "personal_calendar.read@v1", operation:,
        presentation: Syrus::Host::PermissionCapabilityPresentation.for(capability: "personal_calendar.read@v1", operation:),
        effects: %i[network_read confidential_read credential_use], risk: :medium,
        requestable_roles: ROLES, defaults: ROLES.index_with { :ask }, maximum_autonomy: :permanent,
        authority_durations: %i[invocation chat_session job permanent], resource_scope: :connected_account,
        classifier: ->(_arguments) { { operation:, effects: %i[network_read confidential_read credential_use], risk: :medium, confidence: :certain } },
        fingerprint_normalizer: ->(arguments) { arguments.to_h.stringify_keys.slice("account_id", "acting_mode", "starts_at", "ends_at", "event_id", "limit") },
        redactor: ->(arguments) { arguments.to_h.stringify_keys.merge("provenance" => "external_untrusted") }
    end
  end
end
