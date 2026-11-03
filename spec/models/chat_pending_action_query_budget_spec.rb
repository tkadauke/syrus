require "rails_helper"

# Regression guard for query amplification in the pending-action confirmation
# job (a single coworker tool-call confirmation once issued ~100 statements).
RSpec.describe ChatPendingActionConfirmationJob, "query budget" do
  # The acceptance bar is strictly below 50 statements.
  SQL_BUDGET = 49

  include ActiveJob::TestHelper

  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:chat) { ChatSession.create!(user: owner, repository:) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url)
  end
  let(:request) do
    chat.pending_actions.create!(
      request_kind: "authorization_request", action: "coworker_tool_call",
      requested_by: "agent", origin: chat, subject: coworker, runtime_role: AgentRole::COWORKER_CHAT,
      payload: { "tool_name" => "read_custom_data", "arguments" => { "query" => "customers" } }
    )
  end
  let(:descriptor) do
    generated = Permissions::CapabilityDescriptorAdapter.for_registry_entry(
      tool_name: "read_custom_data", capability: "custom.read", mutation: true,
      required_roles: [ AgentRole::COWORKER_CHAT ]
    )
    Permissions::CapabilityDescriptor.new(**generated.to_h.merge(defaults: { AgentRole::COWORKER_CHAT => :ask }))
  end
  let(:tool) do
    Class.new do
      def self.call(**) = MCP::Tool::Response.new([ { type: "text", text: "ok" } ])
    end
  end

  # Production caches plugin enablement for a TTL; the test default re-reads it
  # on every provider lookup, which would inflate the count.
  around do |example|
    previous = Thread.current[:syrus_plugin_record_cache_ttl]
    Thread.current[:syrus_plugin_record_cache_ttl] = 60
    example.run
  ensure
    Thread.current[:syrus_plugin_record_cache_ttl] = previous
  end

  before do
    Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main")
    catalog = Mcp::CoworkerToolCatalog::Descriptor.new(
      tool_name: "read_custom_data", capability: "custom.read", ungated: false,
      tier: :essential, tool:, provider: nil
    )
    allow(Mcp::CoworkerToolCatalog).to receive(:resolve).and_return(catalog)
    allow(McpToolRegistry).to receive(:entries).with(surface: :coworker)
      .and_return([ Struct.new(:tool, :descriptor).new(tool, descriptor) ])
    allow(McpToolRegistry).to receive(:tool_name_for).and_return("read_custom_data")
    allow(Mcp::Sidecar).to receive(:chat_tools).and_return([ tool ])
    request.authorization_items.create!(
      kind: "operation", capability: "custom.read", capability_version: 1,
      operation: "custom.read/read_custom_data", operation_version: 1,
      resource_type: "none", resource_scope: {}, normalized_arguments: { "query" => "customers" },
      invocation_fingerprint: Permissions::InvocationFingerprint.call(descriptor:, arguments: request.payload.fetch("arguments")),
      effects: [ "internal_write" ], policy_chain: [], decisive_rule: {}, requested_durations: [ "invocation" ]
    )
  end

  def count_queries
    statements = []
    callback = lambda do |_n, _s, _f, _id, payload|
      statements << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached] ||
        payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE SAVEPOINT|PRAGMA)\b/i) ||
        payload[:sql].match?(/sqlite_master/)
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    statements
  end

  it "confirms a representative pending action within the SQL budget" do
    item = request.authorization_items.first
    Permissions::CoworkerAuthorizationDecision.new(request:, item:, user: owner).call(decision: "approved")

    statements = count_queries { described_class.perform_now(request.id) }

    expect(request.reload.state).to eq("confirmed")
    expect(request.payload["tool_result"]).to eq("ok")
    # Baseline before the fix was 87 statements here (100 in production).
    expect(statements.size).to be <= SQL_BUDGET,
      "expected <= #{SQL_BUDGET} statements, got #{statements.size}:\n#{statements.join("\n")}"
  end

  it "loads each chat-session scoped record once during a confirmation" do
    item = request.authorization_items.first
    Permissions::CoworkerAuthorizationDecision.new(request:, item:, user: owner).call(decision: "approved")

    statements = count_queries { described_class.perform_now(request.id) }

    # chat attachments -> repository used to be resolved a dozen times.
    expect(statements.count { |sql| sql.include?(%(INNER JOIN "chat_attachments")) }).to be <= 2
    expect(statements.count { |sql| sql.start_with?(%(SELECT "chat_sessions".* FROM "chat_sessions" WHERE)) }).to be <= 1
    expect(statements.count { |sql| sql.start_with?(%(SELECT "coworkers".* FROM "coworkers" WHERE)) }).to be <= 2
  end

  it "stays idempotent when the confirmation job runs twice" do
    item = request.authorization_items.first
    Permissions::CoworkerAuthorizationDecision.new(request:, item:, user: owner).call(decision: "approved")

    described_class.perform_now(request.id)
    expect { described_class.perform_now(request.id) }.not_to change { request.reload.transitions.count }
    expect(request.reload.state).to eq("confirmed")
  end
end
