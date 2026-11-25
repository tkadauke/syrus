module WorkflowOutcomeOverrides
  class Authority
    def self.call(user:, arguments:, repository: nil)
      descriptor = Permissions::WorkflowOutcomeOverrideActions.descriptor_for(
        "execute_workflow_outcome_override", required_roles: [ AgentRole::CHAT_PLANNER ]
      )
      Permissions::PolicyEvaluator.new(
        descriptor:, role: AgentRole::CHAT_PLANNER, resource_scope: {},
        rules: PermissionRule.active.for_owner(user).map(&:to_policy_rule),
        context: { subject_selector_type: "interactive_chat", subject_repository_id: repository&.id }, arguments:
      ).call
    end
  end
end
