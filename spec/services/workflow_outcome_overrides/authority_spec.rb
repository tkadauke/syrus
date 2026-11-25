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
end
