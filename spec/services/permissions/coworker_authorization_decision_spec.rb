require "rails_helper"

RSpec.describe Permissions::CoworkerAuthorizationDecision do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:chat) { ChatSession.create!(user: owner, repository:) }
  let(:coworker) do
    Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url
    )
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
    Permissions::CapabilityDescriptor.new(**generated.to_h.merge(
      defaults: { AgentRole::COWORKER_CHAT => :ask }
    ))
  end
  let(:operation) do
    request.authorization_items.create!(
      kind: "operation", capability: "custom.read", capability_version: 1,
      operation: "custom.read/read_custom_data", operation_version: 1,
      resource_type: "none", resource_scope: {}, normalized_arguments: { "query" => "customers" },
      invocation_fingerprint: Permissions::InvocationFingerprint.call(
        descriptor:, arguments: request.payload.fetch("arguments")
      ), effects: [ "internal_write" ], policy_chain: [], decisive_rule: {},
      requested_durations: [ "invocation" ]
    )
  end

  before do
    Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main")
    tool = Class.new
    catalog = Mcp::CoworkerToolCatalog::Descriptor.new(
      tool_name: "read_custom_data", capability: "custom.read", ungated: false,
      tier: :essential, tool:, provider: nil
    )
    allow(Mcp::CoworkerToolCatalog).to receive(:resolve).and_return(catalog)
    allow(McpToolRegistry).to receive(:entries).with(surface: :coworker)
      .and_return([ Struct.new(:tool, :descriptor).new(tool, descriptor) ])
    operation
  end

  it "issues one atomic invocation claim and enqueues execution after approval" do
    expect {
      result = described_class.new(request:, item: operation, user: owner).call(decision: "approved")
      expect(result.execution_enqueued).to be(true)
    }.to have_enqueued_job(ChatPendingActionConfirmationJob).with(request.id)
    expect(request.reload).to be_confirming
    expect(operation.reload.authorized_invocation).to have_attributes(
      state: "issued", authority_type: "PermissionLease", tool_name: "read_custom_data"
    )
    expect(coworker.grants).to be_empty
  end

  it "denies the operation without issuing or enqueueing it" do
    result = described_class.new(request:, item: operation, user: owner).call(decision: "denied")

    expect(result.execution_enqueued).to be(false)
    expect(operation.reload).to be_denied
    expect(operation.authorized_invocation).to be_nil
    expect(request.reload).to be_rejected
  end
end
