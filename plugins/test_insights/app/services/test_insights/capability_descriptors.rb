module TestInsights
  module CapabilityDescriptors
    ROLES = (AgentRole::CHAT_ROLES + AgentRole::WORKFLOW_ROLES).uniq.freeze
    CAPABILITY = "test_insights.evidence@v1"
    OPERATIONS = {
      "list_repository_test_insights" => [ "list", %w[repository_id] ],
      "read_test_insight" => [ "read", %w[test_identity_id] ],
      "read_job_test_results" => [ "read_job_results", %w[job_id] ],
      "read_run_test_results" => [ "read_run_results", %w[run_id] ],
      "compare_test_runtime" => [ "compare_runtime", %w[repository_id test_identity_ids] ]
    }.freeze

    def self.for(tool_name)
      name, scope = OPERATIONS.fetch(tool_name)
      Permissions::PluginToolDescriptor.build(
        capability: CAPABILITY, operation: "test_insights/#{name}@v1",
        effects: %i[confidential_read], risk: :low, roles: ROLES, default: :allow,
        maximum_autonomy: :permanent, authority_durations: Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS,
        scope_keys: scope
      )
    end
  end
end
