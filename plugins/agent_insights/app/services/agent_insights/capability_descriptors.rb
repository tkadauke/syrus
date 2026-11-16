module AgentInsights
  module CapabilityDescriptors
    ROLES = (AgentRole::CHAT_ROLES + [ AgentRole::AGENT_INSIGHT, AgentRole::COWORKER_CHAT, AgentRole::COWORKER ]).uniq.freeze
    OPERATIONS = {
      "submit_insight" => [ "suggestions", "submit", %i[internal_write], :medium, :ask, %w[repository_id] ],
      "update_insight" => [ "suggestions", "update", %i[internal_write], :medium, :ask, %w[target_insight_id] ],
      "retire_insight" => [ "suggestions", "retire", %i[internal_write], :medium, :ask, %w[target_insight_id insight_ids] ],
      "accept_insight" => [ "suggestions", "accept", %i[internal_write], :medium, :ask, %w[insight_id insight_ids] ],
      "dismiss_insight" => [ "suggestions", "dismiss", %i[internal_write], :medium, :ask, %w[insight_id insight_ids] ],
      "list_insights" => [ "evidence", "list", %i[confidential_read], :low, :allow, %w[repository_id] ],
      "read_insight" => [ "evidence", "read", %i[confidential_read], :low, :allow, %w[insight_id id] ],
      "read_run_transcript" => [ "evidence", "read_transcript", %i[confidential_read], :medium, :allow, %w[run_id] ],
      "list_recent_workflows" => [ "evidence", "list_workflows", %i[confidential_read], :low, :allow, %w[repository_id] ]
    }.freeze

    def self.for(tool_name)
      family, name, effects, risk, default, scope = OPERATIONS.fetch(tool_name)
      mutation = effects.include?(:internal_write)
      Permissions::PluginToolDescriptor.build(
        capability: "agent_insights.#{family}@v1", operation: "agent_insights/#{name}@v1",
        effects:, risk:, roles: ROLES, default:, maximum_autonomy: mutation ? :invocation : :permanent,
        authority_durations: mutation ? %i[invocation] : Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS,
        scope_keys: scope
      )
    end
  end
end
