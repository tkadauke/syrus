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
    expect(tools).to all(include(coworker_safe: true, capability: "mysql.read"))
    expect(described_class.coworker_grants.first).to include(default_policy: "confirm", maximum_policy: "auto")
  end

  it "advertises no MySQL tools to a coworker until mysql.read is granted" do
    owner = Factories.user(admin: true)
    connection = Factories.mysql_connection(agentic_access_enabled: true)
    MysqlDbBrowser::CredentialMaterial.store!(connection, "secret", user: owner, scope_type: "user", scope_id: owner.id)
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-tools",
      workspace_repo: "https://github.com/example/workspace.git")
    chat = ChatSession.create!(user: owner)
    chat.define_singleton_method(:coworker) { coworker }
    PluginRecord.find_by!(name: "mysql_db_browser").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!

    expect(Mcp::Sidecar.mcp_tools_for(described_class, tier: :essential, chat_session: chat, policy: :coworker)).to be_empty

    coworker.grants.create!(capability: "mysql.read", approval_policy: "confirm", scope: connection.id)
    expect(Mcp::Sidecar.mcp_tools_for(described_class, tier: :essential, chat_session: chat, policy: :coworker)
      .map { |tool| McpToolRegistry.tool_name_for(tool) }).to contain_exactly(
        "mysql_db_browser_list_connections", "mysql_db_browser_list_databases",
        "mysql_db_browser_list_tables", "mysql_db_browser_describe_table", "mysql_db_browser_execute_query"
      )
  end

  it "dispatches string-keyed params without revealing an unusable legacy connection" do
    disabled = Factories.mysql_connection(agentic_access_enabled: false)

    response = described_class.new.handle("mysql_db_browser_list_databases", { "mysql_connection_id" => disabled.id }, {})

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("was not found")
  end

  it "reports unknown tool names without dispatching" do
    response = described_class.new.handle("nonexistent_tool", {}, {})

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Unknown MySQL DB Browser tool")
  end
end
