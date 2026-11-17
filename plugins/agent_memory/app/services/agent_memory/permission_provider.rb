module AgentMemory
  class PermissionProvider
    include Syrus::Plugin::PermissionProvider

    ROLES = (AgentRole::CHAT_ROLES + AgentRole::WORKFLOW_ROLES + [ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ]).uniq.freeze
    CAPABILITY = "agent_memory.entries@v1"
    EFFECTS = {
      "read_memory" => %i[confidential_read], "search_memories" => %i[confidential_read],
      "list_memories" => %i[confidential_read], "admin_read_memory_audit_history" => %i[confidential_read],
      "write_memory" => %i[internal_write], "publish_memory" => %i[internal_write communication],
      "unpublish_memory" => %i[internal_write], "delete_memory" => %i[internal_write destructive]
    }.freeze
    OPERATIONS = EFFECTS.keys.index_with { |name| "agent_memory.entries/#{name}@v1" }.freeze

    class << self
      def normalize(arguments) = arguments.to_h.stringify_keys.sort.to_h
      def redact(arguments) = normalize(arguments).transform_values { |value| value.is_a?(String) && value.length > 120 ? "[REDACTED MEMORY CONTENT]" : value }
    end

    EFFECTS.each do |name, effects|
      operation = OPERATIONS.fetch(name)
      mutation = effects.include?(:internal_write)
      risk = effects.include?(:destructive) ? :high : (mutation ? :medium : :low)
      defaults = ROLES.index_with do |role|
        mutation || role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ]) ? :ask : :allow
      end
      register_capability(
        capability: CAPABILITY, operation:, presentation: Permissions::CapabilityPresentation.for(capability: CAPABILITY, operation:),
        effects:, risk:, requestable_roles: ROLES, defaults:,
        maximum_autonomy: mutation ? :invocation : :permanent,
        authority_durations: mutation ? %i[invocation] : Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS,
        resource_scope: { type: :none }, classifier: ->(_arguments) { { operation:, effects:, risk:, confidence: :certain } },
        fingerprint_normalizer: method(:normalize), redactor: method(:redact)
      )
    end
  end
end
