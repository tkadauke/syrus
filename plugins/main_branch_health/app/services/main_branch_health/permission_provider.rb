module MainBranchHealth
  class PermissionProvider
    include Syrus::Plugin::PermissionProvider

    ROLES = McpToolSet::REPORTING_ROLES
    CAPABILITY = "main_branch_health.reporting@v1"
    OPERATIONS = { "report_main_concern" => "main_branch_health.reporting/report_main_concern@v1" }.freeze

    class << self
      def normalize(arguments) = arguments.to_h.stringify_keys.sort.to_h
    end

    OPERATIONS.each_value do |operation|
      register_capability(
        capability: CAPABILITY, operation:, presentation: Permissions::CapabilityPresentation.for(capability: CAPABILITY, operation:),
        essential: true, # a low-risk report about the run's own evidence
        effects: %i[internal_write], risk: :low, requestable_roles: ROLES, defaults: ROLES.index_with(:allow),
        maximum_autonomy: :permanent, authority_durations: Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS,
        resource_scope: { type: :none },
        classifier: ->(_arguments) { { operation:, effects: %i[internal_write], risk: :low, confidence: :certain } },
        fingerprint_normalizer: method(:normalize), redactor: method(:normalize)
      )
    end
  end
end
