require "rails_helper"

RSpec.describe MysqlDbBrowser::ListConnectionsTool do
  let(:chat_session) { ChatSession.create!(user: Factories.user(admin: true)) }

  def capture_queries
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  it "returns only safe connection metadata, including agentic and write flags" do
    enabled = Factories.mysql_connection(
      label: "Production reporting",
      host: "prod-db.internal",
      port: 3307,
      username: "reporter",
      password: "s3cret",
      default_database: "reporting",
      agentic_access_enabled: true,
      allow_writes: false
    )
    disabled = Factories.mysql_connection(
      label: "Archive",
      host: "archive-db.internal",
      username: "archive_user",
      password: "archive-secret",
      default_database: "archive",
      agentic_access_enabled: false,
      allow_writes: true
    )

    response = described_class.call(server_context: { chat_session: chat_session })

    expect(response.error?).to be(false)
    payload = JSON.parse(response.content.first[:text])
    expect(payload.fetch("mysql_connections")).to contain_exactly(
      {
        "id" => enabled.id,
        "label" => "Production reporting",
        "default_database" => "reporting",
        "agentic_access_enabled" => true,
        "allow_writes" => false,
        "created_at" => enabled.created_at.iso8601,
        "updated_at" => enabled.updated_at.iso8601
      }
    )

    serialized = response.content.first[:text]
    expect(serialized).not_to include("prod-db.internal")
    expect(serialized).not_to include("reporter")
    expect(serialized).not_to include("s3cret")
    expect(serialized).not_to include("archive-db.internal")
    expect(serialized).not_to include("archive_user")
    expect(serialized).not_to include("archive-secret")
  end

  it "bulk-loads backing credentials when listing connections" do
    3.times do |index|
      connection = Factories.mysql_connection(label: "Connection #{index}", agentic_access_enabled: true)
      MysqlDbBrowser::CredentialMaterial.store!(
        connection, "secret-#{index}", user: chat_session.user,
        scope_type: "user", scope_id: chat_session.user.id
      )
    end

    queries = capture_queries do
      response = described_class.call(server_context: { chat_session: chat_session })
      expect(response.error?).to be(false)
    end

    credential_queries = queries.grep(/FROM ["`]?credential_store_credentials["`]?/i)
    expect(credential_queries.size).to eq(1)
  end

  it "audits coworker connection discovery with the coworker identity" do
    PluginRecord.find_by!(name: "mysql_db_browser").update!(enabled: true)
    PluginRecord.find_by!(name: "coworkers").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    owner = chat_session.user
    connection = Factories.mysql_connection(agentic_access_enabled: true)
    MysqlDbBrowser::CredentialMaterial.store!(connection, "secret", user: owner, scope_type: "user", scope_id: owner.id)
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-list-mysql",
      workspace_repo: "https://github.com/example/workspace.git")
    coworker.grants.create!(capability: "mysql.read", approval_policy: "auto", scope: connection.id)
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat_session, role: "main")
    chat_session.define_singleton_method(:coworker) { coworker }

    response = described_class.call(server_context: { chat_session: chat_session })

    expect(response.error?).to be(false)
    expect(MysqlQueryAudit.last).to have_attributes(
      mysql_connection: connection, user: owner, agent_actor: coworker, read_only: true, success: true,
      statement: "/* MCP tool call: mysql_db_browser_list_connections */"
    )
  end
end
