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

  it "renders every preset rule for confirmation and applies none before confirmation" do
    preset = Permissions::PermissionPreset.new(
      name: "interactive_observer", label: "Interactive observer",
      description: "Read-only interactive access.",
      rules: [ {
        capability: descriptor.capability, operation: descriptor.operation,
        role: AgentRole::CHAT_PLANNER, policy: :allow, resource_scope: {}, constraints: {}
      } ]
    )
    allow(Permissions::Catalog).to receive(:presets).and_return("interactive_observer" => preset)

    response = Mcp::Tools::ApplyPermissionPresetTool.call(
      server_context: context, subject_selector_type: "interactive_chat", preset: "interactive_observer"
    )
    pending = ChatPendingAction.find(body(response).fetch(:pending_action_id))

    expect(pending.payload.fetch("drafts")).to contain_exactly(a_hash_including(
      "capability" => descriptor.capability, "operation" => descriptor.operation,
      "policy" => "allow"
    ))
    expect(PendingActions::ApplyPermissionPreset.new(pending).presentation_detail)
      .to eq("ALLOW example.records/read@v1 for #{AgentRole::CHAT_PLANNER} (interactive_chat)")
    expect(PermissionRule.count).to eq(0)

    pending.confirm!(user: user)
    expect(PermissionRule.active.sole).to have_attributes(
      capability: descriptor.capability, operation: descriptor.operation, policy: "allow"
    )
  end

  it "applies the exact callable preset drafts that the operator confirms" do
    render_count = 0
    preset = Permissions::PermissionPreset.new(
      name: "changing_observer", label: "Changing observer",
      description: "A context-dependent recommendation.",
      rules: lambda do |_context|
        render_count += 1
        [ {
          capability: descriptor.capability, operation: descriptor.operation,
          role: AgentRole::CHAT_PLANNER, policy: render_count == 1 ? :allow : :deny,
          resource_scope: {}, constraints: {}
        } ]
      end
    )
    allow(Permissions::Catalog).to receive(:presets).and_return("changing_observer" => preset)

    response = Mcp::Tools::ApplyPermissionPresetTool.call(
      server_context: context, subject_selector_type: "interactive_chat", preset: "changing_observer"
    )
    pending = ChatPendingAction.find(body(response).fetch(:pending_action_id))

    expect(PendingActions::ApplyPermissionPreset.new(pending).presentation_detail)
      .to start_with("ALLOW ")
    pending.confirm!(user: user)

    expect(render_count).to eq(1)
    expect(PermissionRule.active.sole).to have_attributes(policy: "allow")
  end

  it "rejects unknown presets before creating a pending action" do
    allow(Permissions::Catalog).to receive(:presets).and_return({})

    response = Mcp::Tools::ApplyPermissionPresetTool.call(
      server_context: context, subject_selector_type: "interactive_chat", preset: "missing"
    )

    expect(response.content.first[:text]).to include("unknown permission preset")
    expect(ChatPendingAction.count).to eq(0)
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

  it "rejects an ineligible role during confirmation" do
    response = Mcp::Tools::GrantPermissionTool.call(
      server_context: context, role: AgentRole::WORKFLOW_IMPLEMENT, subject_selector_type: "workflow_role",
      subject_selector_id: AgentRole::WORKFLOW_IMPLEMENT,
      capability: descriptor.capability, operation: descriptor.operation, resource_scope: {}
    )
    pending = ChatPendingAction.find(body(response).fetch(:pending_action_id))

    expect { pending.confirm!(user: user) }.to raise_error(ArgumentError, /role is not eligible/)
    expect(PermissionRule.count).to eq(0)
    expect(pending.reload).to be_failed
  end

  it "rejects a subject selector that does not match the eligible role" do
    response = Mcp::Tools::GrantPermissionTool.call(
      server_context: context, role: AgentRole::CHAT_PLANNER, subject_selector_type: "workflow_role",
      subject_selector_id: AgentRole::WORKFLOW_IMPLEMENT,
      capability: descriptor.capability, operation: descriptor.operation, resource_scope: {}
    )
    pending = ChatPendingAction.find(body(response).fetch(:pending_action_id))

    expect { pending.confirm!(user: user) }.to raise_error(ArgumentError, /subject selector does not match/)
    expect(PermissionRule.count).to eq(0)
    expect(pending.reload).to be_failed
  end

  it "explains only leases available to the requested lifecycle context" do
    lease = Permissions::Management.new(user).lease!({
      "role" => AgentRole::CHAT_PLANNER, "subject_selector_type" => "interactive_chat",
      "capability" => descriptor.capability, "operation" => descriptor.operation,
      "resource_scope" => {}, "duration" => "chat_session", "chat_session_id" => chat_session.id
    }, actor: user)

    matching = body(Mcp::Tools::ExplainPermissionTool.call(
      server_context: context, role: AgentRole::CHAT_PLANNER, subject_selector_type: "interactive_chat",
      capability: descriptor.capability, operation: descriptor.operation, chat_session_id: chat_session.id
    ))
    unrelated = body(Mcp::Tools::ExplainPermissionTool.call(
      server_context: context, role: AgentRole::CHAT_PLANNER, subject_selector_type: "interactive_chat",
      capability: descriptor.capability, operation: descriptor.operation, chat_session_id: chat_session.id + 1
    ))

    expect(matching).to include(policy: "allow")
    expect(matching.dig(:decisive_rule, :id)).to eq("permission-lease-#{lease.id}")
    expect(unrelated).to include(policy: "ask", decisive_rule: nil)
  end

  it "explains invocation fingerprints without consuming the lease" do
    lease = Permissions::Management.new(user).lease!({
      "role" => AgentRole::CHAT_PLANNER, "subject_selector_type" => "interactive_chat",
      "capability" => descriptor.capability, "operation" => descriptor.operation,
      "resource_scope" => {}, "duration" => "invocation", "arguments" => { "record_id" => 7 }
    }, actor: user)

    matching = body(Mcp::Tools::ExplainPermissionTool.call(
      server_context: context, role: AgentRole::CHAT_PLANNER, subject_selector_type: "interactive_chat",
      capability: descriptor.capability, operation: descriptor.operation, arguments: { record_id: 7 }
    ))
    changed = body(Mcp::Tools::ExplainPermissionTool.call(
      server_context: context, role: AgentRole::CHAT_PLANNER, subject_selector_type: "interactive_chat",
      capability: descriptor.capability, operation: descriptor.operation, arguments: { record_id: 8 }
    ))

    expect(matching).to include(policy: "allow")
    expect(changed).to include(policy: "ask", decisive_rule: nil)
    expect(lease.reload.used_count).to eq(0)
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
