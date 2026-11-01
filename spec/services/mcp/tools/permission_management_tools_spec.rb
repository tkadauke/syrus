require "rails_helper"

RSpec.describe "permission management MCP tools" do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user) }
  let(:context) { { chat_session: chat_session, chat_message: chat_session.messages.create!(role: "user", content: { text: "Manage permissions" }) } }
  let(:descriptor) do
    Permissions::CapabilityDescriptor.new(
      capability: "example.records@v1", operation: "example.records/read@v1",
      effects: [ :confidential_read ], risk: :medium,
      requestable_roles: [ AgentRole::CHAT_PLANNER ], defaults: { AgentRole::CHAT_PLANNER => :ask },
      maximum_autonomy: :permanent, authority_durations: %i[invocation chat_session job permanent],
      resource_scope: { type: :none }, classifier: ->(_arguments) { {} },
      fingerprint_normalizer: ->(arguments) { arguments }, redactor: ->(arguments) { arguments }
    )
  end

  def body(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  before do
    allow(Permissions::Catalog).to receive(:find!).and_return(descriptor)
  end

  it "never grants authority before the operator confirms the pending action" do
    response = Mcp::Tools::GrantPermissionTool.call(
      server_context: context, role: AgentRole::CHAT_PLANNER, subject_selector_type: "interactive_chat",
      capability: descriptor.capability, operation: descriptor.operation, resource_scope: {}
    )

    pending = ChatPendingAction.find(body(response).fetch(:pending_action_id))
    expect(pending).to be_pending
    expect(PermissionRule.count).to eq(0)

    pending.confirm!(user: user)

    expect(PermissionRule.active.sole).to have_attributes(
      owner_user: user, policy: "allow", capability: descriptor.capability,
      operation: descriptor.operation, created_by_user: user
    )
  end

  it "creates confirmed deny rules and exposes them through the read API" do
    response = Mcp::Tools::DenyPermissionTool.call(
      server_context: context, role: AgentRole::CHAT_PLANNER, subject_selector_type: "interactive_chat",
      capability: descriptor.capability, operation: descriptor.operation, resource_scope: {}
    )
    ChatPendingAction.find(body(response).fetch(:pending_action_id)).confirm!(user: user)

    listed = body(Mcp::Tools::ListPermissionsTool.call(server_context: context))
    expect(listed.fetch(:rules)).to contain_exactly(a_hash_including(policy: "deny", capability: descriptor.capability))
  end

  it "requires a second confirmed action to revoke a rule and invalidates unclaimed authority" do
    rule = Permissions::Management.new(user).deny!({
      "role" => AgentRole::CHAT_PLANNER, "subject_selector_type" => "interactive_chat",
      "capability" => descriptor.capability, "operation" => descriptor.operation, "resource_scope" => {}
    }, actor: user)

    response = Mcp::Tools::RevokePermissionTool.call(permission_rule_id: rule.id, server_context: context)
    expect(rule.reload.revoked_at).to be_nil

    ChatPendingAction.find(body(response).fetch(:pending_action_id)).confirm!(user: user)
    expect(rule.reload.revoked_at).to be_present
  end

  it "creates lifecycle-bound leases only after confirmation" do
    response = Mcp::Tools::CreatePermissionLeaseTool.call(
      server_context: context, role: AgentRole::CHAT_PLANNER, subject_selector_type: "interactive_chat",
      capability: descriptor.capability, operation: descriptor.operation, resource_scope: {},
      duration: "chat_session", chat_session_id: chat_session.id
    )
    pending = ChatPendingAction.find(body(response).fetch(:pending_action_id))
    expect(PermissionLease.count).to eq(0)

    pending.confirm!(user: user)

    expect(PermissionLease.sole).to have_attributes(
      owner_user: user, issued_by_user: user, duration_kind: "chat_session", chat_session: chat_session
    )
  end

  it "revalidates the descriptor autonomy ceiling during confirmation" do
    invocation_only = Permissions::CapabilityDescriptor.new(**descriptor.to_h.merge(
      maximum_autonomy: :invocation, authority_durations: [ :invocation ]
    ))
    allow(Permissions::Catalog).to receive(:find!).and_return(invocation_only)
    response = Mcp::Tools::GrantPermissionTool.call(
      server_context: context, role: AgentRole::CHAT_PLANNER, subject_selector_type: "interactive_chat",
      capability: invocation_only.capability, operation: invocation_only.operation, resource_scope: {}
    )
    pending = ChatPendingAction.find(body(response).fetch(:pending_action_id))

    expect { pending.confirm!(user: user) }.to raise_error(ArgumentError, /unsupported authority duration/)
    expect(PermissionRule.count).to eq(0)
    expect(pending.reload).to be_failed
  end

  it "cancels only the confirming user's authorization request after confirmation" do
    request = ChatPendingAction.create!(
      user: user, chat_session: chat_session, origin: chat_session, subject: user,
      request_kind: "authorization_request", requested_by: "agent", state: "pending",
      deduplication_key: SecureRandom.hex(16)
    )
    response = Mcp::Tools::CancelAuthorizationRequestTool.call(authorization_request_id: request.id, server_context: context)
    expect(request.reload).to be_pending

    ChatPendingAction.find(body(response).fetch(:pending_action_id)).confirm!(user: user)
    expect(request.reload).to be_cancelled
  end
end
