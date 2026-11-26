require "rails_helper"

RSpec.describe WorkflowOutcomeOverrides::Authority do
  it "evaluates the supplied agent role and selector instead of impersonating a planner" do
    user = Factories.user
    evaluator = instance_double(Permissions::PolicyEvaluator, call: :decision)
    allow(Permissions::PolicyEvaluator).to receive(:new).and_return(evaluator)

    result = described_class.call(
      user:, arguments: { job_id: 1 }, role: AgentRole::COWORKER,
      subject_selector_type: "agent"
    )

    expect(result).to eq(:decision)
    expect(Permissions::PolicyEvaluator).to have_received(:new).with(hash_including(
      role: AgentRole::COWORKER,
      context: hash_including(subject_selector_type: "agent")
    ))
  end

  it "matches an agent-specific deny by its exact coworker id" do
    user = Factories.user
    descriptor = Permissions::WorkflowOutcomeOverrideActions.descriptor_for(
      "execute_workflow_outcome_override", required_roles: [ AgentRole::COWORKER_CHAT ]
    )
    PermissionRule.create!(
      owner_user: user, created_by_user: user, updated_by_user: user,
      subject_selector_type: "agent", subject_selector_id: "42",
      capability: descriptor.capability, operation: descriptor.operation,
      resource_type: "none", resource_scope: {}, constraints: {}, policy: "deny",
      policy_layer: "agent", source: "operator", provenance: {}, subject_role_keys: []
    )

    decision = described_class.call(
      user:, arguments: { job_id: 1 }, role: AgentRole::COWORKER_CHAT,
      subject_selector_type: "agent", subject_selector_id: "42"
    )

    expect(decision).to be_deny
  end
end
