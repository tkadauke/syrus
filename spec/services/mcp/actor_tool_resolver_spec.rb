require "rails_helper"

# Lifecycle of a plugin-provided operator-chat tool (MySQL-browser shaped): the
# sidecar generates it per actor and hangs the descriptor on the tool, so it
# is absent from the static McpToolRegistry. Request, approval and replay must
# all resolve it the same way, and fail closed when the plugin goes away.
RSpec.describe Mcp::ActorToolResolver do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:chat) { ChatSession.create!(user:, repository:) }
  let(:role) { McpToolContext.from_chat_session(chat).role }
  let(:tool_name) { "plugindb_execute_query" }
  let(:arguments) { { "sql" => "select 1" } }
  let(:descriptor) do
    Permissions::CapabilityDescriptorAdapter.for_registry_entry(
      tool_name:, capability: "plugindb.query", mutation: true, required_roles: [ role ]
    )
  end
  let(:calls) { [] }
  let(:plugin_tool) do
    recorded = calls
    MCP::Tool.define(name: tool_name, description: "run sql", input_schema: { type: "object" }) do |server_context:, **params|
      recorded << params
      MCP::Tool::Response.new([ { type: "text", text: "1 row" } ])
    end.tap do |tool|
      captured = descriptor
      tool.define_singleton_method(:capability_descriptor) { captured }
    end
  end
  let(:plugin_enabled) { true }

  before do
    allow(Mcp::Sidecar).to receive(:chat_tools).and_wrap_original do |original, *args, **kwargs|
      base = original.call(*args, **kwargs)
      plugin_enabled ? base + [ plugin_tool ] : base
    end
  end

  def build_request
    ChatPendingAction.create!(
      request_kind: "authorization_request", action: "authorized_tool_call", user:, repository:,
      origin: chat, chat_session: chat, subject: user, runtime_role: role,
      purpose: "Invoke #{tool_name}",
      payload: { "tool_name" => tool_name, "arguments" => arguments }
    ).tap do |request|
      request.authorization_items.create!(
        kind: "operation", capability: "plugindb.query", capability_version: 1,
        operation: "plugindb.query/execute", operation_version: 1, resource_type: "none",
        resource_scope: {}, normalized_arguments: arguments,
        invocation_fingerprint: Permissions::InvocationFingerprint.call(descriptor:, arguments:),
        effects: [ "internal_write" ], policy_chain: [], decisive_rule: {},
        requested_durations: [ "invocation" ]
      )
    end
  end

  describe ".resolve" do
    it "finds a plugin tool and its attached descriptor" do
      expect(McpToolRegistry.entry_for(plugin_tool)).to be_nil
      resolution = described_class.resolve(tool_name:, chat_session: chat)
      expect(resolution.tool).to equal(plugin_tool)
      expect(resolution.descriptor).to equal(descriptor)
    end

    it "fails closed once the plugin tool is no longer offered" do
      allow(self).to receive(:plugin_enabled).and_return(false)
      expect(described_class.resolve(tool_name:, chat_session: chat)).to be_nil
    end

    it "still resolves core registry tools through the registry descriptor" do
      core = McpToolRegistry.entries(surface: :chat).first
      name = McpToolRegistry.tool_name_for(core.tool)
      allow(Mcp::Sidecar).to receive(:chat_tools).and_return([ core.tool ])
      expect(described_class.resolve(tool_name: name, chat_session: chat).descriptor).to equal(core.descriptor)
    end
  end

  describe "approval and replay" do
    it "issues the authorized invocation on approval, then replays exactly once" do
      request = build_request
      item = request.authorization_items.first

      result = Permissions::CoworkerAuthorizationDecision.new(request:, item:, user:).call(decision: "approved")
      expect(result.execution_enqueued).to be(true)
      expect(item.reload.authorized_invocation).to have_attributes(state: "issued", tool_name: tool_name)

      action = PendingActions::CoworkerToolCall.new(request.reload)
      action.authorize_execution!
      action.execute

      expect(calls).to eq([ { sql: "select 1" } ])
      expect(item.reload.authorized_invocation.state).to eq("succeeded")
      expect(request.reload.payload["tool_result"]).to eq("1 row")
      expect { PendingActions::CoworkerToolCall.new(request.reload).execute }.to raise_error(ArgumentError)
      expect(calls.size).to eq(1)
    end

    it "fails closed on approval when the plugin was removed after the request" do
      request = build_request
      allow(self).to receive(:plugin_enabled).and_return(false)

      expect {
        Permissions::CoworkerAuthorizationDecision.new(request:, item: request.authorization_items.first, user:)
          .call(decision: "approved")
      }.to raise_error(ArgumentError, /no longer available/)
      expect(calls).to be_empty
    end

    it "fails closed on replay when the plugin was removed after approval" do
      request = build_request
      Permissions::CoworkerAuthorizationDecision.new(request:, item: request.authorization_items.first, user:)
        .call(decision: "approved")
      allow(self).to receive(:plugin_enabled).and_return(false)

      expect { PendingActions::CoworkerToolCall.new(request.reload).authorize_execution! }
        .to raise_error(ArgumentError, /no longer available/)
      expect { PendingActions::CoworkerToolCall.new(request.reload).execute }
        .to raise_error(ArgumentError, /no longer available/)
      expect(calls).to be_empty
    end

    it "rejects replay when the arguments drifted from the approved fingerprint" do
      request = build_request
      Permissions::CoworkerAuthorizationDecision.new(request:, item: request.authorization_items.first, user:)
        .call(decision: "approved")
      request.update!(payload: request.payload.merge("arguments" => { "sql" => "drop table x" }))

      expect { PendingActions::CoworkerToolCall.new(request.reload).authorize_execution! }
        .to raise_error(ArgumentError, /no longer matches/)
      expect(calls).to be_empty
    end
  end
end
