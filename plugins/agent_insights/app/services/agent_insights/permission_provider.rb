module AgentInsights
  class PermissionProvider
    include Syrus::Plugin::PermissionProvider

    ROLES = (AgentRole::CHAT_ROLES + [ AgentRole::AGENT_INSIGHT, AgentRole::COWORKER_CHAT, AgentRole::COWORKER ]).uniq.freeze
    CAPABILITY = "agent_insights.investigation@v1"
    MUTATIONS = %w[submit_insight update_insight retire_insight accept_insight dismiss_insight].freeze
    TOOLS = (MUTATIONS + %w[list_insights read_insight read_run_transcript list_recent_workflows]).freeze
    OPERATIONS = TOOLS.index_with { |name| "agent_insights.investigation/#{name}@v1" }.freeze

    class << self
      def normalize(arguments) = arguments.to_h.stringify_keys.sort.to_h
      def redact(arguments) = normalize(arguments).transform_values { |value| value.is_a?(String) && value.length > 200 ? "[REDACTED CONTENT]" : value }
    end

    TOOLS.each do |name|
      operation = OPERATIONS.fetch(name)
      mutation = MUTATIONS.include?(name)
      effects = mutation ? %i[internal_write] : %i[confidential_read]
      register_capability(
        capability: CAPABILITY, operation:, presentation: Permissions::CapabilityPresentation.for(capability: CAPABILITY, operation:),
        effects:, risk: mutation ? :medium : :low, requestable_roles: ROLES, defaults: ROLES.index_with { mutation ? :ask : :allow },
        maximum_autonomy: mutation ? :invocation : :permanent,
        authority_durations: mutation ? %i[invocation] : Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS,
        resource_scope: { type: :none }, classifier: ->(_arguments) { { operation:, effects:, risk: mutation ? :medium : :low, confidence: :certain } },
        fingerprint_normalizer: method(:normalize), redactor: method(:redact)
      )
    end
  end
end
