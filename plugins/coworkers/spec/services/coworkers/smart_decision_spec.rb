require "rails_helper"

RSpec.describe Permissions::SmartDecision do
  include ActiveJob::TestHelper

  let(:owner) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url) }
  let(:chat) { ChatSession.create!(user: owner, repository: repository, title: "Maya") }
  let(:scope) { Syrus::EffectScope.new(label: "smart decision spec") }
  let(:arguments) { { handle: "maya", text: "Hello" } }

  before do
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    Coworkers::ChatExtension.install_into(scope)
    PluginRecord.find_by!(name: "coworkers").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    assigned = coworker
    chat.define_singleton_method(:coworker) { assigned }
    allow(Coworkers::MessageCoworkerTool).to receive(:call).and_return(Mcp::Tools.success(delivered: true))
  end

  after { scope.dispose }

  # The shipped coworker.message descriptor is invocation-only; this catalog
  # variant offers durable authority for the same capability and operation.
  def durable_descriptor(durations: %i[ invocation chat_session job permanent ], autonomy: :permanent, effects: %i[internal_write], risk: :medium, schema: Permissions::ResourceScopeSchema.new(type: :none))
    Permissions::CapabilityDescriptor.new(
      capability: "coworker.message@v1", operation: "coworker.message/message_coworker@v1", effects:, risk:, requestable_roles: [ "chat:coworker" ], defaults: { "chat:coworker" => :ask },
      maximum_autonomy: autonomy, authority_durations: durations,
      resource_scope: schema,
      classifier: ->(_arguments) { { operation: "coworker.message/message_coworker@v1", confidence: :certain } },
      fingerprint_normalizer: ->(arguments) { arguments }, redactor: ->(arguments) { arguments }
    )
  end

  def stub_catalog(descriptor)
    allow(Permissions::Catalog).to receive(:descriptors) { [ descriptor ] }
  end

  def request_action
    tool = Mcp::Sidecar.chat_tools(chat.reload, tier: :essential).find { |t| McpToolRegistry.tool_name_for(t) == "message_coworker" }
    payload = JSON.parse(tool.call(**arguments, server_context: { chat_session: chat }).content.first.fetch(:text))
    chat.pending_actions.find(payload.fetch("pending_action_id"))
  end

  let(:action) { request_action }
  let(:item) { action.authorization_items.find_by!(kind: "operation") }
  let(:smart) { described_class.new(request: action, item: item, user: owner) }

  it "offers no adaptive action for an invocation-only capability" do
    expect(smart.option).to be_nil
  end

  it "falls back to the chat duration when the descriptor forbids permanent authority" do
    stub_catalog(durable_descriptor(durations: %i[ invocation chat_session ], autonomy: :chat_session))
    expect(smart.option).to include(kind: "allow_chat", duration: "chat_session")
  end

  it "offers the strongest safe duration derived from the descriptor" do
    stub_catalog(durable_descriptor)
    option = smart.option
    expect(option).to be_present
    expect(option).to include(kind: "always_allow_similar", duration: "permanent")
    expect(option[:context]).to include(coworker: "Maya", operation: item.operation)
    expect(option[:summary]).to include(:allows, :excludes)
    expect(option[:draft][:subject]).to include(type: "agent", id: coworker.id.to_s)
  end

  it "is withheld from other users and unapproved prerequisites" do
    expect(described_class.new(request: action, item: item, user: Factories.user).option).to be_nil
  end

  it "applies the rule and authorizes the invocation atomically, linking the rule" do
    stub_catalog(durable_descriptor)
    option = smart.option
    expect do
      Permissions::CoworkerAuthorizationDecision.new(request: action, item: item, user: owner)
        .call(decision: "approved", smart: { duration: option[:duration], digest: option[:digest] })
    end.to change(PermissionRule, :count).by(1)

    expect(item.reload).to have_attributes(state: "approved", selected_duration: option[:duration])
    expect(item.resulting_authority).to be_a(PermissionRule)
    expect(item.authorized_invocation.authority).not_to eq(item.resulting_authority)
    expect(item.authorized_invocation).to be_present
  end

  it "creates neither authority nor an approved item for a stale preview" do
    stub_catalog(durable_descriptor)
    option = smart.option
    expect do
      expect do
        Permissions::CoworkerAuthorizationDecision.new(request: action, item: item, user: owner)
          .call(decision: "approved", smart: { duration: option[:duration], digest: "stale" })
      end.to raise_error(Permissions::RuleDraft::Stale)
    end.not_to change { PermissionRule.count + PermissionLease.count }

    expect(item.reload).to be_pending
    expect(item.authorized_invocation).to be_nil
    expect(action.reload).to be_pending
  end

  it "rejects durations that are not offered" do
    stub_catalog(durable_descriptor)
    expect do
      Permissions::CoworkerAuthorizationDecision.new(request: action, item: item, user: owner)
        .call(decision: "approved", smart: { duration: "invocation", digest: "x" })
    end.to raise_error(ArgumentError)
    expect(item.reload).to be_pending
  end

  it "creates exactly one rule when the decision is submitted twice" do
    stub_catalog(durable_descriptor)
    option = smart.option
    decide = -> { Permissions::CoworkerAuthorizationDecision.new(request: action, item: item, user: owner).call(decision: "approved", smart: { duration: option[:duration], digest: option[:digest] }) }
    decide.call
    expect { expect { decide.call }.to raise_error(described_class::AlreadyDecided) }.not_to change { PermissionRule.count + PermissionLease.count }
  end

  it "offers a permanent rule for a safe read" do
    stub_catalog(durable_descriptor(effects: %i[local_read], risk: :low))
    expect(smart.option).to include(kind: "always_allow_similar", duration: "permanent")
  end

  it "keeps a scoped mutation to its exact normalized resource scope" do
    schema = Permissions::ResourceScopeSchema.new(
      type: :repository,
      normalize: ->(scope, context:) { { repository_id: Integer(scope.to_h.stringify_keys.fetch("repository_id")) } },
      compare: ->(left, right, context:) { left == right ? :equal : :disjoint },
      label: ->(scope, context:) { "repository ##{scope.fetch('repository_id')}" }
    )
    stub_catalog(durable_descriptor(schema: schema))
    item.update!(resource_scope: { "repository_id" => repository.id }, resource_type: "repository")

    option = described_class.new(request: action.reload, item: item.reload, user: owner).option
    expect(option[:draft][:resource_scope]).to eq("repository_id" => repository.id)
    expect(option[:context][:resource_scope_label]).to eq("repository ##{repository.id}")
    expect(option[:summary][:excludes].join(" ")).to include("repository ##{repository.id}")
  end

  it "refuses the second of two callers racing on the same request" do
    stub_catalog(durable_descriptor)
    option = smart.option
    # Both callers loaded the pending request before either decided; the lock
    # makes the loser re-read it as already decided.
    first = ChatPendingAction.find(action.id)
    second = ChatPendingAction.find(action.id)
    decide = lambda do |request|
      Permissions::CoworkerAuthorizationDecision.new(request: request, item: request.authorization_items.find(item.id), user: owner)
        .call(decision: "approved", smart: { duration: option[:duration], digest: option[:digest] })
    end

    outcomes = [ first, second ].map do |request|
      decide.call(request)
      :applied
    rescue described_class::AlreadyDecided
      :refused
    end

    expect(outcomes).to eq(%i[applied refused])
    expect(PermissionRule.where(capability: "coworker.message@v1").or(PermissionRule.where(capability: "coworker.message")).count).to eq(1)
    expect(AuthorizedInvocation.where(pending_action_item: item).count).to eq(1)
    expect(item.reload).to be_approved
  end

  it "withholds the option when an explicit deny rule applies" do
    stub_catalog(durable_descriptor)
    action
    descriptor = durable_descriptor
    PermissionRule.create!(
      owner_user: owner, created_by_user: owner, updated_by_user: owner, subject_selector_type: "agent",
      subject_selector_id: coworker.id.to_s, subject_role_keys: [], capability: descriptor.capability,
      operation: descriptor.operation, resource_type: descriptor.resource_scope.type.to_s, resource_scope: {},
      constraints: {}, policy: "deny", policy_layer: "agent", source: "operator", provenance: {}
    )
    expect(smart.option).to be_nil
  end
end
