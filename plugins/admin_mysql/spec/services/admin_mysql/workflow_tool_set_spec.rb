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
      "admin_mysql_status"
    )
  end

  it "does not expose the kill-query tool to ordinary implement workflow contexts" do
    allow(AdminMysql).to receive(:mysql?).and_return(true)

    names = described_class.tool_definitions(context: context).map { |tool| tool.fetch(:name) }

    expect(names).not_to include("admin_mysql_kill_query")
  end

  it "refuses direct kill-query invocation from an ordinary implement workflow context" do
    allow(AdminMysql).to receive(:mysql?).and_return(true)
    allow(McpToolContext).to receive(:from_server_context).and_return(context)
    expect(AdminMysql::Inspector).not_to receive(:new)

    response = described_class.new.handle("admin_mysql_kill_query", { "thread_id" => 123 }, { run_id: 1 })

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Unknown Admin MySQL workflow tool")
  end

  it "still allows ordinary implement workflow contexts to invoke status" do
    allow(AdminMysql).to receive(:mysql?).and_return(true)
    allow(McpToolContext).to receive(:from_server_context).and_return(context)
    payload = { processlist: [] }
    inspector = instance_double(AdminMysql::Inspector, snapshot: payload)
    allow(AdminMysql::Inspector).to receive(:new).and_return(inspector)

    response = described_class.new.handle("admin_mysql_status", { "limit" => 5 }, { run_id: 1 })

    expect(response.error?).to be(false)
    expect(response.content.first[:text]).to eq(JSON.pretty_generate(payload))
    expect(inspector).to have_received(:snapshot).with(limit: 5)
  end

  it "does not expose tools to non-implement workflow roles" do
    allow(AdminMysql).to receive(:mysql?).and_return(true)
    review_context = instance_double(McpToolContext, role: AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER, repository: repository)

    expect(described_class.available_for_context?(review_context)).to be(false)
    expect(described_class.tool_definitions(context: review_context)).to eq([])
  end

  it "refuses direct status invocation from non-implement workflow contexts" do
    allow(AdminMysql).to receive(:mysql?).and_return(true)
    review_context = instance_double(McpToolContext, role: AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER, repository: repository)
    allow(McpToolContext).to receive(:from_server_context).and_return(review_context)
    expect(AdminMysql::Inspector).not_to receive(:new)

    response = described_class.new.handle("admin_mysql_status", {}, { run_id: 1 })

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Unauthorized")
  end
end
