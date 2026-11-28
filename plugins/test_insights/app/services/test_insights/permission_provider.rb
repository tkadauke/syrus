module TestInsights
  class PermissionProvider
    include Syrus::Host::PermissionProvider

    ROLES = (Syrus::Host::AgentRole::CHAT_ROLES + Syrus::Host::AgentRole::WORKFLOW_ROLES).uniq.freeze
    CAPABILITY = "test_insights.evidence@v1"
    OPERATIONS = %w[
      list_repository_test_insights read_test_insight read_job_test_results
      read_run_test_results compare_test_runtime
    ].index_with { |name| "test_insights.evidence/#{name}@v1" }.freeze

    class << self
      def normalize(arguments) = arguments.to_h.stringify_keys.sort.to_h
      def classifier(operation) = ->(_arguments) { { operation:, effects: %i[local_read], risk: :low, confidence: :certain } }
    end

    OPERATIONS.each_value do |operation|
      register_capability(
        capability: CAPABILITY, operation:, presentation: Syrus::Host::CapabilityPresentation.for(capability: CAPABILITY, operation:),
        essential: true, # research reads of test evidence
        effects: %i[local_read], risk: :low, requestable_roles: ROLES, defaults: ROLES.index_with(:allow),
        maximum_autonomy: :permanent, authority_durations: Syrus::Host::CapabilityDescriptor::AUTHORITY_DURATIONS,
        resource_scope: { type: :none }, classifier: classifier(operation), fingerprint_normalizer: method(:normalize), redactor: method(:normalize)
      )
    end
  end
end
