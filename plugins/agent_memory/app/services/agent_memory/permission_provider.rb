module AgentMemory
  class PermissionProvider
    include Syrus::Host::PermissionProvider

    ROLES = (AgentRole::CHAT_ROLES + AgentRole::WORKFLOW_ROLES + [ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ]).uniq.freeze
    CAPABILITY = "agent_memory.entries@v1"
    EFFECTS = {
      "read_memory" => %i[confidential_read], "search_memories" => %i[confidential_read],
      "list_memories" => %i[confidential_read], "admin_read_memory_audit_history" => %i[confidential_read],
      "write_memory" => %i[internal_write], "publish_memory" => %i[internal_write communication],
      "unpublish_memory" => %i[internal_write], "delete_memory" => %i[internal_write destructive]
    }.freeze
    OPERATIONS = EFFECTS.keys.index_with { |name| "agent_memory.entries/#{name}@v1" }.freeze

    # A user's private memories are the agent's own context: reading them and
    # writing a new one cross no consequence barrier, so they are essential
    # (always allowed, never deniable) while scope validation, content policy,
    # duplicate detection and provenance stay in the tools. Publishing shares
    # state with other users and deleting destroys it, so both stay gated.
    ESSENTIAL = %w[read_memory search_memories list_memories write_memory].freeze
    DENIABLE_REASONS = {
      "unpublish_memory" => :shared_state,
      "admin_read_memory_audit_history" => :instance_wide_observability
    }.freeze

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
        capability: CAPABILITY, operation:, presentation: Syrus::Host::CapabilityPresentation.for(capability: CAPABILITY, operation:),
        essential: ESSENTIAL.include?(name), deniable_reason: DENIABLE_REASONS[name],
        effects:, risk:, requestable_roles: ROLES, defaults:,
        maximum_autonomy: mutation ? :invocation : :permanent,
        authority_durations: mutation ? %i[invocation] : Syrus::Host::CapabilityDescriptor::AUTHORITY_DURATIONS,
        resource_scope: { type: :none }, classifier: ->(_arguments) { { operation:, effects:, risk:, confidence: :certain } },
        fingerprint_normalizer: method(:normalize), redactor: method(:redact)
      )
    end
  end
end
