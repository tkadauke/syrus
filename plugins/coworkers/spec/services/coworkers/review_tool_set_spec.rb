require "rails_helper"

RSpec.describe Coworkers::ReviewToolSet do
  it "exposes only the narrow memory capability to coworker review Runs" do
    repository = Factories.repository
    allowed = instance_double(McpToolContext, repository:, role: AgentRole::WORKFLOW_COWORKER_REVIEWER)
    denied = instance_double(McpToolContext, repository:, role: AgentRole::WORKFLOW_IMPLEMENT)
    allow(Coworkers).to receive(:enabled?).and_return(true)

    expect(described_class.tool_definitions(context: allowed)).to contain_exactly(
      hash_including(name: "update_coworker_review_memory", capability: "review.memory.write", mutation: true),
      hash_including(name: "submit_coworker_review", capability: "review.verdict.submit", mutation: true)
    )
    expect(described_class.tool_definitions(context: denied)).to be_empty
  end

  it "limits the memory tool to reviewer Runs while allowing manual Runs to submit verdicts" do
    manual = instance_double(McpToolContext, repository: Factories.repository, role: AgentRole::WORKFLOW_MANUAL)
    allow(Coworkers).to receive(:enabled?).and_return(true)

    expect(described_class.tool_definitions(context: manual).map { |d| d[:name] }).to eq(%w[submit_coworker_review])
  end
end
