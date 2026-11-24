module CognitiveReview
  class PermissionProvider
    include Syrus::Host::PermissionProvider

    ROLES = Syrus::Host::AgentRoles::WORKFLOW_ROLES.freeze
    CAPABILITY = "cognitive_review.notes@v1"
    OPERATION = "cognitive_review.notes/submit@v1"

    class << self
      def normalize(arguments) = arguments.to_h.stringify_keys.sort.to_h
      def redact(arguments) = normalize(arguments).merge("notes" => "[REDACTED REVIEW NOTES]").compact
    end

    register_capability(
      capability: CAPABILITY, operation: OPERATION,
      presentation: Syrus::Host::PermissionCapabilityPresentation.for(capability: CAPABILITY, operation: OPERATION),
      # The reviewer's own notes are bounded workflow output. Essential.
      essential: true,
      effects: %i[internal_write], risk: :medium, requestable_roles: ROLES, defaults: ROLES.index_with(:ask),
      maximum_autonomy: :job, authority_durations: %i[invocation job], resource_scope: { type: :none },
      classifier: ->(_arguments) { { operation: OPERATION, effects: %i[internal_write], risk: :medium, confidence: :certain } },
      fingerprint_normalizer: method(:normalize), redactor: method(:redact)
    )
  end
end
