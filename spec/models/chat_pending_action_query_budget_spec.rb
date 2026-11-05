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
  let(:participant) { Factories.user }
  let(:share_recipient) { Factories.user }
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
    chat.chat_participants.create!(user: participant, role: "member", joined_at: Time.current)
    ChatShare.create!(chat_session: chat, target: share_recipient, shared_by_user: owner)
    ChatMessage.insert_all!(24.times.map do |index|
      {
        chat_session_id: chat.id, role: index.even? ? "user" : "assistant",
        content: { "text" => "Production-scale history message #{index}" },
        created_at: index.minutes.ago, updated_at: index.minutes.ago,
        entity_revision: 1
      }
    end)
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
    sql_time = 0.0
    callback = lambda do |_n, started, finished, _id, payload|
      statements << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached] ||
        payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE SAVEPOINT|PRAGMA)\b/i) ||
        payload[:sql].match?(/sqlite_master/)
      sql_time += finished - started unless payload[:name] == "SCHEMA" || payload[:cached]
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    fingerprints = statements.tally { |sql| sql.squish.gsub(/\?/, "<bind>") }
    Rails.logger.info(
      "[pending_action_query_profile] statements=#{statements.size} " \
      "sql_ms=#{(sql_time * 1000).round(1)} wall_ms=#{(elapsed * 1000).round(1)} " \
      "fingerprints=#{fingerprints.sort_by { |_sql, count| -count }.to_h.to_json}"
    )
    { statements:, sql_time:, elapsed:, fingerprints: }
  end

  def approve_request
    item = request.authorization_items.first
    Permissions::CoworkerAuthorizationDecision.new(request:, item:, user: owner).call(decision: "approved")
  end

  it "confirms a representative pending action within the SQL budget" do
    approve_request

    profile = count_queries { described_class.perform_now(request.id) }
    statements = profile.fetch(:statements)

    expect(request.reload.state).to eq("confirmed")
    expect(request.payload["tool_result"]).to eq("ok")
    expect(request.outcome_message).to be_present
    expect(chat.reload.last_message_at).to eq(request.outcome_message.created_at)
    # Baseline before the fix was 87 statements here (100 in production).
    failure_message =
      "expected <= #{SQL_BUDGET} statements, got #{statements.size} " \
      "(SQL #{(profile.fetch(:sql_time) * 1000).round(1)}ms, wall #{(profile.fetch(:elapsed) * 1000).round(1)}ms):\n" \
      "#{statements.join("\n")}"
    expect(statements.size).to be <= SQL_BUDGET, failure_message
  end

  it "loads each chat-session scoped record once during a confirmation" do
    approve_request

    statements = count_queries { described_class.perform_now(request.id) }.fetch(:statements)

    # chat attachments -> repository used to be resolved a dozen times.
    expect(statements.count { |sql| sql.include?(%(INNER JOIN "chat_attachments")) }).to be <= 2
    expect(statements.count { |sql| sql.start_with?(%(SELECT "chat_sessions".* FROM "chat_sessions" WHERE)) }).to be <= 1
    expect(statements.count { |sql| sql.start_with?(%(SELECT "coworkers".* FROM "coworkers" WHERE)) }).to be <= 2
  end

  it "stays idempotent when the confirmation job runs twice" do
    approve_request

    described_class.perform_now(request.id)
    expect { described_class.perform_now(request.id) }.not_to change { request.reload.transitions.count }
    expect(request.reload.state).to eq("confirmed")
  end

  it "does not execute an already-confirmed action loaded by another worker" do
    approve_request
    stale_worker_action = described_class.new

    described_class.perform_now(request.id)

    expect(tool).not_to receive(:call)
    expect(stale_worker_action.perform(request.id)).to be(false)
    expect(request.reload.transitions.where(to_state: "confirmed").count).to eq(1)
  end

  it "does not execute a stale request whose authorization was denied" do
    item = request.authorization_items.first
    item.decide!("denied", principal: owner, reason: "Not allowed")

    expect(tool).not_to receive(:call)
    expect(described_class.perform_now(request.id)).to be(false)
    expect(item.reload).to be_denied
    expect(request.reload).not_to be_confirming
  end

  it "records failures and delivers the outcome without losing the message event" do
    approve_request
    allow(tool).to receive(:call).and_raise(ArgumentError, "upstream rejected the request")
    allow(AppEvents).to receive(:broadcast_chat_resource).and_call_original

    expect(described_class.perform_now(request.id)).to be(false)

    expect(request.reload).to be_failed
    expect(request.execution_error).to include("upstream rejected the request")
    expect(request.outcome_message).to be_present
    expect(AppEvents).to have_received(:broadcast_chat_resource).with(hash_including(
      chat_session_id: chat.id,
      changed: [ "messages" ],
      payload: hash_including(action: "invalidate_messages", reason: "targeted_invalidation")
    ))
  end

  describe "concurrent workers", :ci_only do
    self.use_transactional_tests = false

    after do
      ChatSession.where(id: chat.id).destroy_all
      Coworkers::Coworker.where(id: coworker.id).destroy_all
      Repository.where(id: repository.id).destroy_all
      User.where(id: [ owner.id, participant.id, share_recipient.id ]).destroy_all
      ActiveRecord::Base.connection_handler.clear_all_connections!
    end

    it "executes exactly once when two confirmation jobs start together" do
      approve_request
      executions = Queue.new
      allow(tool).to receive(:call) do
        executions << true
        MCP::Tool::Response.new([ { type: "text", text: "ok" } ])
      end
      ready = Queue.new
      start = Queue.new
      results = Queue.new

      workers = 2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            start.pop
            results << described_class.perform_now(request.id)
          end
        end
      end
      workers.size.times { ready.pop }
      workers.size.times { start << true }
      workers.each(&:join)

      expect(2.times.map { results.pop }).to contain_exactly(true, false)
      expect(executions.size).to eq(1)
      expect(request.reload).to be_confirmed
      expect(request.transitions.where(to_state: "confirmed").count).to eq(1)
    end
  end
end
