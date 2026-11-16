module OperatorBriefing
  module CapabilityDescriptors
    ROLES = AgentRole::WORKFLOW_ROLES.freeze
    OPERATIONS = {
      "submit_briefing_block" => [ "authoring", "submit_block", true ],
      "submit_dive_report" => [ "authoring", "submit_dive_report", true ],
      "read_briefing_git_diff" => [ "evidence", "read_git_diff", false ],
      "list_briefing_recent_workflows" => [ "evidence", "list_recent_workflows", false ],
      "read_briefing" => [ "evidence", "read", false ],
      "list_briefing_topics" => [ "evidence", "list_topics", false ],
      "read_briefing_topic" => [ "evidence", "read_topic", false ]
    }.freeze

    def self.for(tool_name)
      family, name, write = OPERATIONS.fetch(tool_name)
      effects = write ? %i[internal_write] : %i[confidential_read]
      Permissions::PluginToolDescriptor.build(
        capability: "operator_briefing.#{family}@v1", operation: "operator_briefing/#{name}@v1",
        effects:, risk: write ? :medium : :low, roles: ROLES, default: write ? :ask : :allow,
        maximum_autonomy: write ? :invocation : :job,
        authority_durations: write ? %i[invocation] : %i[invocation job],
        scope_keys: %w[briefing_id repository_id topic_id]
      )
    end
  end
end
