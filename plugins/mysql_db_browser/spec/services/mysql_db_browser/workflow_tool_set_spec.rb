require "rails_helper"

RSpec.describe MysqlDbBrowser::WorkflowToolSet do
  let(:repository) { instance_double(Repository) }
  let(:context) { instance_double(McpToolContext, role: AgentRole::WORKFLOW_IMPLEMENT, repository: repository) }

  it "is unavailable when the plugin is disabled" do
    allow(MysqlDbBrowser).to receive(:enabled?).and_return(false)
    Factories.mysql_connection(agentic_access_enabled: true)

    expect(described_class.available_for?(repository)).to be(false)
    expect(described_class.available_for_context?(context)).to be(false)
  end

  it "is unavailable when no connection has opted into agentic access" do
    allow(MysqlDbBrowser).to receive(:enabled?).and_return(true)
    Factories.mysql_connection(agentic_access_enabled: false)

    expect(described_class.available_for_context?(context)).to be(false)
  end

  it "is available to implement agents once at least one connection has opted in" do
    allow(MysqlDbBrowser).to receive(:enabled?).and_return(true)
    Factories.mysql_connection(agentic_access_enabled: true)

    expect(described_class.available_for_context?(context)).to be(true)
    expect(described_class.tool_definitions(context: context).map { |tool| tool.fetch(:name) }).to contain_exactly(
      "mysql_db_browser_list_databases",
      "mysql_db_browser_list_tables",
      "mysql_db_browser_describe_table",
      "mysql_db_browser_execute_query"
    )
  end

  it "does not expose tools to non-implement workflow roles" do
    allow(MysqlDbBrowser).to receive(:enabled?).and_return(true)
    Factories.mysql_connection(agentic_access_enabled: true)
    review_context = instance_double(McpToolContext, role: AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER, repository: repository)

    expect(described_class.available_for_context?(review_context)).to be(false)
    expect(described_class.tool_definitions(context: review_context)).to eq([])
  end

  it "delegates handling to ChatToolSet" do
    disabled = Factories.mysql_connection(agentic_access_enabled: false)

    response = described_class.new.handle("mysql_db_browser_list_databases", { "mysql_connection_id" => disabled.id }, {})

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Agentic access is disabled")
  end
end
