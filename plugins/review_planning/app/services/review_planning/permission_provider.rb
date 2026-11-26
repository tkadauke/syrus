module ReviewPlanning
  class PermissionProvider
    include Syrus::Host::PermissionProvider

    ROLES = [ "workflow:summary_test_plan" ].freeze
    CAPABILITY = "review_planning.submit@v1"
    OPERATIONS = { "submit_review_plan" => "review_planning.submit/submit_review_plan@v1" }.freeze

    class << self
      def normalize(arguments) = arguments.to_h.stringify_keys.sort.to_h
      def redact(arguments) = normalize(arguments).transform_values { |value| value.is_a?(String) && value.length > 200 ? "[REDACTED REVIEW NOTE]" : value }
    end

    OPERATIONS.each_value do |operation|
      register_capability(
        capability: CAPABILITY, operation:, presentation: Syrus::Host::PermissionCapabilityPresentation.for(capability: CAPABILITY, operation:),
        # The agent records its own self-review on its own workflow; the only
        # outward effect is the step's PR comment, posted by the harness.
        essential: true,
        effects: %i[internal_write], risk: :low, requestable_roles: ROLES, defaults: ROLES.index_with(:allow),
        maximum_autonomy: :invocation, authority_durations: %i[invocation], resource_scope: { type: :none },
        classifier: ->(_arguments) { { operation:, effects: %i[internal_write], risk: :low, confidence: :certain } },
        fingerprint_normalizer: method(:normalize), redactor: method(:redact)
      )
    end
  end
end
