module OperatorBriefing
  class PermissionProvider
    include Syrus::Host::PermissionProvider

    ROLES = (Syrus::Host::AgentRole::WORKFLOW_ROLES + [ Syrus::Host::AgentRole::AGENT_INSIGHT ]).uniq.freeze
    CAPABILITY = "operator_briefing.evidence@v1"
    MUTATIONS = %w[submit_briefing_block submit_dive_report].freeze
    TOOLS = (MUTATIONS + %w[read_briefing_git_diff list_briefing_recent_workflows read_briefing list_briefing_topics read_briefing_topic]).freeze
    OPERATIONS = TOOLS.index_with { |name| "operator_briefing.evidence/#{name}@v1" }.freeze

    class << self
      def normalize(arguments) = arguments.to_h.stringify_keys.sort.to_h
      def redact(arguments) = normalize(arguments).transform_values { |value| value.is_a?(String) && value.length > 200 ? "[REDACTED BRIEFING CONTENT]" : value }
    end

    TOOLS.each do |name|
      operation = OPERATIONS.fetch(name)
      mutation = MUTATIONS.include?(name)
      effects = mutation ? %i[internal_write] : %i[confidential_read]
      register_capability(
        capability: CAPABILITY, operation:, presentation: Permissions::CapabilityPresentation.for(capability: CAPABILITY, operation:),
        # The briefing agent's evidence reads and its own briefing output are
        # bounded workflow work with no consequence outside the briefing.
        essential: true,
        effects:, risk: mutation ? :medium : :low, requestable_roles: ROLES, defaults: ROLES.index_with { mutation ? :ask : :allow },
        maximum_autonomy: mutation ? :invocation : :job,
        authority_durations: mutation ? %i[invocation] : %i[invocation job], resource_scope: { type: :none },
        classifier: ->(_arguments) { { operation:, effects:, risk: mutation ? :medium : :low, confidence: :certain } },
        fingerprint_normalizer: method(:normalize), redactor: method(:redact)
      )
    end
  end
end
