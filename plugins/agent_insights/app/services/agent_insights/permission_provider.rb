module AgentInsights
  class PermissionProvider
    include Syrus::Host::PermissionProvider

    ROLES = (AgentRole::CHAT_ROLES + [ AgentRole::AGENT_INSIGHT, AgentRole::COWORKER_CHAT, AgentRole::COWORKER ]).uniq.freeze
    CAPABILITY = "agent_insights.investigation@v1"
    MUTATIONS = %w[submit_insight update_insight retire_insight accept_insight dismiss_insight].freeze
    TOOLS = (MUTATIONS + %w[list_insights read_insight read_run_transcript list_recent_workflows]).freeze
    OPERATIONS = TOOLS.index_with { |name| "agent_insights.investigation/#{name}@v1" }.freeze

    # The insight agent's own output and the reads it investigates with are
    # essential. Triage decisions that change what the operator acts on, and
    # reading another run's raw transcript, stay deniable.
    ESSENTIAL = %w[submit_insight update_insight list_insights read_insight list_recent_workflows].freeze
    DENIABLE_REASONS = {
      "retire_insight" => :material_control, "accept_insight" => :material_control,
      "dismiss_insight" => :material_control, "read_run_transcript" => :confidential_cross_boundary
    }.freeze

    class << self
      def normalize(arguments) = arguments.to_h.stringify_keys.sort.to_h
      def redact(arguments) = normalize(arguments).transform_values { |value| value.is_a?(String) && value.length > 200 ? "[REDACTED CONTENT]" : value }
    end

    TOOLS.each do |name|
      operation = OPERATIONS.fetch(name)
      mutation = MUTATIONS.include?(name)
      effects = mutation ? %i[internal_write] : %i[confidential_read]
      defaults = ROLES.index_with do |role|
        mutation || role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ]) ? :ask : :allow
      end
      register_capability(
        capability: CAPABILITY, operation:, presentation: Syrus::Host::CapabilityPresentation.for(capability: CAPABILITY, operation:),
        essential: ESSENTIAL.include?(name), deniable_reason: DENIABLE_REASONS[name],
        effects:, risk: mutation ? :medium : :low, requestable_roles: ROLES, defaults:,
        maximum_autonomy: mutation ? :invocation : :permanent,
        authority_durations: mutation ? %i[invocation] : Syrus::Host::CapabilityDescriptor::AUTHORITY_DURATIONS,
        resource_scope: { type: :none }, classifier: ->(_arguments) { { operation:, effects:, risk: mutation ? :medium : :low, confidence: :certain } },
        fingerprint_normalizer: method(:normalize), redactor: method(:redact)
      )
    end
  end
end
