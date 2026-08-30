require "rails_helper"

RSpec.describe MysqlDbBrowser::ChatToolSet do
  let(:chat_session) { instance_double(ChatSession) }

  it "is unavailable when the plugin is disabled" do
    allow(MysqlDbBrowser).to receive(:enabled?).and_return(false)
    Factories.mysql_connection(agentic_access_enabled: true)

    expect(described_class.available_for?(chat_session, tier: :essential)).to be(false)
  end

  it "is available when connections exist so agents can inspect safe access metadata" do
    allow(MysqlDbBrowser).to receive(:enabled?).and_return(true)
    Factories.mysql_connection(agentic_access_enabled: false)

    expect(described_class.available_for?(chat_session, tier: :essential)).to be(true)
  end

  it "is unavailable when no connection has been configured" do
    allow(MysqlDbBrowser).to receive(:enabled?).and_return(true)

    expect(described_class.available_for?(chat_session, tier: :essential)).to be(false)
  end

  it "is available once at least one connection exists" do
    allow(MysqlDbBrowser).to receive(:enabled?).and_return(true)
    Factories.mysql_connection(agentic_access_enabled: true)

    expect(described_class.available_for?(chat_session, tier: :essential)).to be(true)
    expect(described_class.available_for?(chat_session, tier: :deferred)).to be(true)
  end

  it "is unavailable for tiers outside essential/deferred" do
    allow(MysqlDbBrowser).to receive(:enabled?).and_return(true)
    Factories.mysql_connection(agentic_access_enabled: true)

    expect(described_class.available_for?(chat_session, tier: :evaluator)).to be(false)
  end

  it "exposes the schema-browse and query-execution tools" do
    tools = described_class.tool_definitions(tier: :essential)

    expect(tools.map { |tool| tool.fetch(:name) }).to contain_exactly(
      "mysql_db_browser_list_connections",
      "mysql_db_browser_list_databases",
      "mysql_db_browser_list_tables",
      "mysql_db_browser_describe_table",
      "mysql_db_browser_execute_query"
    )
    expect(tools.find { |tool| tool.fetch(:name) == "mysql_db_browser_list_databases" }.fetch(:description)).to include("mysql_db_browser_list_connections")
    expect(tools.find { |tool| tool.fetch(:name) == "mysql_db_browser_execute_query" }.dig(:input_schema, :required)).to eq([ "mysql_connection_id", "sql" ])
  end

  it "dispatches to the matching tool class, passing string-keyed params through" do
    disabled = Factories.mysql_connection(agentic_access_enabled: false)

    response = described_class.new.handle("mysql_db_browser_list_databases", { "mysql_connection_id" => disabled.id }, {})

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Agentic access is disabled")
  end

  it "reports unknown tool names without dispatching" do
    response = described_class.new.handle("nonexistent_tool", {}, {})

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Unknown MySQL DB Browser tool")
  end
end
