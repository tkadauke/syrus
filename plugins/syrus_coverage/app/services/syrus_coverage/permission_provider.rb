module SyrusCoverage
  class PermissionProvider
    include Syrus::Plugin::PermissionProvider

    ROLES = AgentRole::WORKFLOW_ROLES.freeze
    CAPABILITY = "syrus_coverage.report@v1"
    OPERATIONS = { "get_coverage_report" => "syrus_coverage.report/get_coverage_report@v1" }.freeze

    class << self
      def normalize(arguments) = arguments.to_h.stringify_keys.sort.to_h
      def classifier(operation) = ->(_arguments) { { operation:, effects: %i[local_read], risk: :low, confidence: :certain } }
    end

    OPERATIONS.each_value do |operation|
      register_capability(
        capability: CAPABILITY, operation:, presentation: Permissions::CapabilityPresentation.for(capability: CAPABILITY, operation:),
        essential: true, # read-only research on the run's own coverage artifact
        effects: %i[local_read], risk: :low, requestable_roles: ROLES, defaults: ROLES.index_with(:allow),
        maximum_autonomy: :permanent, authority_durations: Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS,
        resource_scope: { type: :none }, classifier: classifier(operation), fingerprint_normalizer: method(:normalize), redactor: method(:normalize)
      )
    end
  end
end
