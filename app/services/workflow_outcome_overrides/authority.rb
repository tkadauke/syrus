module WorkflowOutcomeOverrides
  class Authority
    def self.call(user:, arguments:, repository: nil, role:, subject_selector_type:, subject_selector_id: nil)
      descriptor = Permissions::WorkflowOutcomeOverrideActions.descriptor_for(
        "execute_workflow_outcome_override", required_roles: [ role ]
      )
      Permissions::PolicyEvaluator.new(
        descriptor:, role:, resource_scope: {},
        rules: PermissionRule.active.for_owner(user).map(&:to_policy_rule),
        context: { subject_selector_type:, subject_selector_id:,
                   subject_repository_id: repository&.id }.compact, arguments:
      ).call
    end
  end
end
