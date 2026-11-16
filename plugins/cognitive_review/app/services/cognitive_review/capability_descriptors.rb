module CognitiveReview
  module CapabilityDescriptors
    def self.for(tool_name)
      raise KeyError, tool_name unless tool_name == "submit_review_notes"

      Permissions::PluginToolDescriptor.build(
        capability: "cognitive_review.notes@v1", operation: "cognitive_review/submit_notes@v1",
        effects: %i[internal_write], risk: :medium, roles: AgentRole::WORKFLOW_ROLES,
        default: :ask, maximum_autonomy: :invocation, authority_durations: %i[invocation],
        scope_keys: %w[job_id run_id]
      )
    end
  end
end
