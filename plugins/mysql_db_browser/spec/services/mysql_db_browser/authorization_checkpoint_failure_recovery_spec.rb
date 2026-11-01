require "rails_helper"

RSpec.describe "MySQL authorization checkpoint failure recovery", :ci_only do
  let(:user) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user:) }
  let(:chat) { ChatSession.create!(user:, repository:) }

  around do |example|
    original_client_factory = MysqlDbBrowser::QueryExecutor.client_factory
    example.run
  ensure
    MysqlDbBrowser::QueryExecutor.client_factory = original_client_factory
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  before do
    PluginRecord.find_by!(name: "mysql_db_browser").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  def approved_invocation
    request = ChatPendingAction.create!(
      request_kind: "authorization_request", user:, repository:, origin: chat, subject: user,
      runtime_role: "interactive_chat", deduplication_key: "mysql-checkpoint-#{SecureRandom.hex(4)}",
      purpose: "Exercise a protected query"
    )
    item = request.authorization_items.create!(
      kind: "operation", capability: "mysql.data@v1", operation: "mysql.data/read@v1",
      operation_version: 1, resource_type: "mysql_connection",
      resource_scope: { resource_id: connection.id }, normalized_arguments: { sql: "SELECT 1" },
      invocation_fingerprint: "sha256:mysql-read-#{SecureRandom.hex(4)}", effects: %w[network_read]
    )
    item.decide!("approved", principal: user, duration: "invocation")
    AuthorizedInvocation.issue!(pending_action_item: item, tool_name: "mysql_db_browser_execute_query")
  end

  def connection
    @connection ||= Factories.mysql_connection(agentic_access_enabled: true, password: "secret")
  end

  def revalidate(connection_id, context)
    return "plugin_disabled" unless MysqlDbBrowser.enabled?

    MysqlDbBrowser::AgenticAccess.connection!(connection_id, context:)
    true
  rescue MysqlDbBrowser::AgenticAccess::ConnectionNotFound
    "resource_removed"
  end

  def dispatch(invocation, connection_id: connection.id, claim_key: "dispatch-1")
    context = McpToolContext.from_server_context(chat_session: chat)
    result = invocation.claim!(
      fingerprint: invocation.invocation_fingerprint, claimant: user, claim_key:,
      revalidate: ->(_) { revalidate(connection_id, context) }, origin_resumable: ->(_) { true }
    )
    return result unless result.claimed?

    response = MysqlDbBrowser::ExecuteQueryTool.call(
      server_context: { chat_session: chat }, mysql_connection_id: connection_id, sql: "SELECT 1"
    )
    invocation.reload.complete!(claim_key:, status: response.error? ? :failed : :succeeded)
    result
  end

  def counting_client(executions)
    query_result = instance_double(Mysql2::Result, fields: [ "value" ])
    allow(query_result).to receive(:each) { |&block| block.call([ 1 ]) }
    instance_double(Mysql2::Client, close: nil, escape: "", abandon_results!: nil, affected_rows: 0).tap do |client|
      allow(client).to receive(:query) do |sql, **|
        executions << sql
        query_result
      end
    end
  end

  it "does not execute a duplicate delivery twice" do
    invocation = approved_invocation
    executions = []
    MysqlDbBrowser::QueryExecutor.client_factory = ->(**) { counting_client(executions) }

    first = dispatch(invocation)
    executions_after_first_delivery = executions.dup
    duplicate = dispatch(invocation.reload)

    expect(first).to be_claimed
    expect(duplicate).to be_already_claimed
    expect(executions_after_first_delivery).not_to be_empty
    expect(executions).to eq(executions_after_first_delivery)
    expect(MysqlQueryAudit.where(mysql_connection: connection, statement: "SELECT 1").count).to eq(1)
    expect(invocation.reload).to be_succeeded
  end

  it "does not execute an approved invocation after the plugin is disabled" do
    invocation = approved_invocation
    executions = []
    MysqlDbBrowser::QueryExecutor.client_factory = ->(**) { counting_client(executions) }

    PluginRecord.find_by!(name: "mysql_db_browser").update!(enabled: false)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    result = dispatch(invocation)

    expect(result.status).to eq(:revalidation_failed)
    expect(executions).to be_empty
    expect(invocation.reload).to have_attributes(
      state: "invalidated", invalidation_reason: "plugin_disabled", claimed_at: nil
    )
  end

  it "does not execute an approved invocation after the connection is removed" do
    invocation = approved_invocation
    connection_id = connection.id
    executions = []
    MysqlDbBrowser::QueryExecutor.client_factory = ->(**) { counting_client(executions) }

    connection.destroy!
    result = dispatch(invocation, connection_id:)

    expect(result.status).to eq(:revalidation_failed)
    expect(executions).to be_empty
    expect(invocation.reload).to have_attributes(
      state: "invalidated", invalidation_reason: "resource_removed", claimed_at: nil
    )
  end
end
