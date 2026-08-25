require "rails_helper"

RSpec.describe MysqlDbBrowser::ExecuteQueryTool do
  let(:connection) { Factories.mysql_connection(agentic_access_enabled: true) }
  let(:user) { Factories.user }

  def fake_client(rows: [])
    result = instance_double(Mysql2::Result, fields: rows.first&.keys || [])
    allow(result).to receive(:each) { |&block| rows.each(&block) }

    client = instance_double(Mysql2::Client, close: nil, affected_rows: 0)
    allow(client).to receive(:escape) { |value| value.to_s }
    allow(client).to receive(:query).and_return(result)
    allow(client).to receive(:abandon_results!)
    client
  end

  around do |example|
    original = MysqlDbBrowser::QueryExecutor.client_factory
    example.run
    MysqlDbBrowser::QueryExecutor.client_factory = original
  end

  def call(mysql_connection_id:, sql:, server_context:, limit: nil)
    described_class.call(server_context: server_context, mysql_connection_id: mysql_connection_id, sql: sql, limit: limit)
  end

  it "attributes a workflow-run query to the Job owner and audit-logs it" do
    run = Factories.job(user: user).initial_run
    MysqlDbBrowser::QueryExecutor.client_factory = ->(**) { fake_client(rows: [ { "id" => 1 } ]) }

    response = call(mysql_connection_id: connection.id, sql: "SELECT * FROM users", server_context: { run_id: run.id })

    expect(response.error?).to be(false)
    payload = JSON.parse(response.content.first[:text], symbolize_names: true)
    expect(payload[:rows]).to eq([ { id: 1 } ])

    audit = MysqlQueryAudit.last
    expect(audit.user).to eq(user)
    expect(audit.mysql_connection).to eq(connection)
    expect(audit.statement).to eq("SELECT * FROM users")
  end

  it "attributes a chat-issued query to the chat session's user" do
    chat_session = instance_double(ChatSession, user: user)
    MysqlDbBrowser::QueryExecutor.client_factory = ->(**) { fake_client(rows: []) }

    call(mysql_connection_id: connection.id, sql: "SELECT 1", server_context: { chat_session: chat_session })

    expect(MysqlQueryAudit.last.user).to eq(user)
  end

  it "rejects a write statement on a read-only connection without opening a connection" do
    run = Factories.job(user: user).initial_run
    MysqlDbBrowser::QueryExecutor.client_factory = ->(**) { raise "should not connect" }

    response = call(mysql_connection_id: connection.id, sql: "DELETE FROM users", server_context: { run_id: run.id })

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("read-only")
  end

  it "refuses when the connection has agentic access disabled" do
    disabled = Factories.mysql_connection(agentic_access_enabled: false)
    run = Factories.job(user: user).initial_run

    response = call(mysql_connection_id: disabled.id, sql: "SELECT 1", server_context: { run_id: run.id })

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Agentic access is disabled")
    expect(MysqlQueryAudit.count).to eq(0)
  end
end
