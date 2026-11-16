module AgentMemory
  module CapabilityDescriptors
    ROLES = (AgentRole::CHAT_ROLES + AgentRole::WORKFLOW_ROLES + [ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ]).uniq.freeze
    OPERATIONS = {
      "read_memory" => [ "read", %i[confidential_read], :low, :allow ],
      "search_memories" => [ "search", %i[confidential_read], :low, :allow ],
      "list_memories" => [ "list", %i[confidential_read], :low, :allow ],
      "admin_read_memory_audit_history" => [ "read_audit_history", %i[confidential_read], :medium, :ask ],
      "write_memory" => [ "write", %i[internal_write], :medium, :ask ],
      "delete_memory" => [ "delete", %i[internal_write destructive], :high, :ask ],
      "publish_memory" => [ "publish", %i[internal_write confidential_read], :high, :ask ],
      "unpublish_memory" => [ "unpublish", %i[internal_write], :medium, :ask ]
    }.freeze

    def self.for(tool_name)
      name, effects, risk, default = OPERATIONS.fetch(tool_name)
      mutation = effects.include?(:internal_write)
      Permissions::PluginToolDescriptor.build(
        capability: "agent_memory.entries@v1", operation: "agent_memory/#{name}@v1",
        effects:, risk:, roles: ROLES, default:, maximum_autonomy: mutation ? :invocation : :permanent,
        authority_durations: mutation ? %i[invocation] : Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS,
        scope_keys: %w[id memory_id repository_id scope]
      )
    end
  end
end
