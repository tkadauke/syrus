require "rails_helper"

RSpec.describe AdminMysql::WorkflowToolSet do
  let(:repository) { instance_double(Repository, slug: "tkadauke/syrus", upstream_slug: nil) }
  let(:context) { instance_double(McpToolContext, role: AgentRole::WORKFLOW_IMPLEMENT, repository: repository) }

  it "is unavailable outside MySQL" do
    allow(AdminMysql).to receive(:mysql?).and_return(false)

    expect(described_class.available_for?(repository)).to be(false)
    expect(described_class.available_for_context?(context)).to be(false)
  end

  it "is scoped to implement agents on Syrus repositories" do
    allow(AdminMysql).to receive(:mysql?).and_return(true)

    expect(described_class.available_for_context?(context)).to be(true)
    expect(described_class.tool_definitions(context: context).map { |tool| tool.fetch(:name) }).to contain_exactly(
      "admin_mysql_status",
      "admin_mysql_kill_query"
    )
  end

  it "does not expose tools to non-implement workflow roles" do
    allow(AdminMysql).to receive(:mysql?).and_return(true)
    review_context = instance_double(McpToolContext, role: AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER, repository: repository)

    expect(described_class.available_for_context?(review_context)).to be(false)
    expect(described_class.tool_definitions(context: review_context)).to eq([])
  end
end
