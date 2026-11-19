require "rails_helper"

RSpec.describe Permissions::PermanentAuthorityReconciler, :ci_only do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:chat_session) { ChatSession.create!(user:, repository:, title: "Permissions") }
  let(:role) { AgentRole::CHAT_PLANNER }
  let(:schema) { Permissions::ResourceScopeSchema.new(type: :none) }
  let(:send_descriptor) { descriptor("communication.chat/send@v1") }
  let(:delete_descriptor) { descriptor("communication.chat/delete@v1") }

  before do
    allow(Permissions::Catalog).to receive(:descriptors).and_return([ send_descriptor, delete_descriptor ])
    allow(ChatPendingActionConfirmationJob).to receive(:perform_later)
  end

  def descriptor(operation)
    Permissions::CapabilityDescriptor.new(
      capability: "communication.chat@v1", operation:, effects: %i[external_write], risk: :medium,
      requestable_roles: [ role ], defaults: { role => :ask }, maximum_autonomy: :permanent,
      authority_durations: %i[invocation chat_session permanent],
      breadth_ceilings: %i[family tool resource].index_with(:permanent), resource_scope: schema,
      constraint_fields: { "channel" => :string },
      classifier: ->(_arguments) { { operation:, confidence: :certain } },
      fingerprint_normalizer: ->(arguments) { arguments }, redactor: ->(arguments) { arguments }
    )
  end

  def request(key, operation: "communication.chat/send", arguments: {}, owner: user, subject: user, repo: repository, request_role: role)
    session = owner == user && repo == repository ? chat_session : ChatSession.create!(user: owner, repository: repo, title: key)
    ChatPendingAction.create!(
      request_kind: "authorization_request", user: owner, repository: repo, chat_session: session,
      origin: session, subject:, runtime_role: request_role, purpose: key, action: "authorized_tool_call",
      deduplication_key: key, payload: { "tool_name" => operation.tr("./", "_"), "arguments" => arguments }
    ).tap do |record|
      record.authorization_items.create!(
        kind: "operation", capability: "communication.chat", capability_version: 1,
        operation:, operation_version: 1, resource_type: "none", resource_scope: {},
        normalized_arguments: arguments, invocation_fingerprint: "fingerprint-#{key}", effects: [ "external_write" ],
        policy_chain: [], decisive_rule: {}, requested_durations: %w[invocation permanent]
      )
    end
  end

  def permanent_rule(source, breadth: "tool")
    item = source.authorization_items.sole
    draft = Permissions::RuleDraft.from_request_item(user:, request: source, item:, duration: "permanent", breadth:)
    draft.apply!(digest: draft.preview.digest, actor: user)
  end

  it "reconciles every covered exact operation through the existing execution queue without duplicating rules" do
    source = request("source")
    first = request("first")
    second = request("second")
    rule = permanent_rule(source)

    reconciled = described_class.call(rule:, source_request: source)

    expect(reconciled).to contain_exactly(first, second)
    expect([ first.reload.state, second.reload.state ]).to eq(%w[confirming confirming])
    expect(first.authorization_items.sole).to have_attributes(
      state: "approved", selected_duration: "permanent", resulting_authority: rule
    )
    expect(AuthorizedInvocation.where(authority: rule).count).to eq(2)
    expect(PermissionRule.count).to eq(1)
    expect(ChatPendingActionConfirmationJob).to have_received(:perform_later).with(first.id).once
    expect(ChatPendingActionConfirmationJob).to have_received(:perform_later).with(second.id).once

    expect(described_class.call(rule:, source_request: source)).to be_empty
    expect(AuthorizedInvocation.where(authority: rule).count).to eq(2)
  end

  it "uses policy breadth and keeps different operations pending until a family grant covers them" do
    source = request("source")
    same_operation = request("same")
    different_operation = request("different", operation: "communication.chat/delete")

    tool_rule = permanent_rule(source, breadth: "tool")
    expect(described_class.call(rule: tool_rule, source_request: source)).to contain_exactly(same_operation)
    expect(different_operation.reload).to be_pending

    family_source = request("family-source")
    family_rule = permanent_rule(family_source, breadth: "family")
    expect(described_class.call(rule: family_rule, source_request: family_source)).to contain_exactly(different_operation)
  end

  it "leaves requests outside a resource constraint pending" do
    source = request("source", arguments: { "channel" => "releases" })
    covered = request("covered", arguments: { "channel" => "releases" })
    different = request("different", arguments: { "channel" => "incidents" })

    rule = permanent_rule(source, breadth: "resource")

    expect(described_class.call(rule:, source_request: source)).to contain_exactly(covered)
    expect(different.reload).to be_pending
  end

  it "isolates candidates by owner, subject, role, and repository and skips terminal races" do
    source = request("source")
    other_user = Factories.user
    other_repository = Factories.repository(user:)
    different_owner = request("other-owner", owner: other_user, subject: other_user, repo: Factories.repository(user: other_user))
    different_subject = request("other-subject", subject: Factories.user)
    different_role = request("other-role", request_role: AgentRole::CHAT_CODING)
    different_repository = request("other-repository", repo: other_repository)
    cancelled = request("cancelled").tap { |record| record.update!(state: "cancelled") }

    expect(described_class.call(rule: permanent_rule(source), source_request: source)).to be_empty
    expect([ different_owner, different_subject, different_role, different_repository, cancelled ].map { |record| record.reload.state })
      .to eq(%w[pending pending pending pending cancelled])
  end

  it "is invoked by a permanent decision and emits the existing pending-action update" do
    source = request("source")
    sibling = request("sibling")
    draft = Permissions::RuleDraft.from_request_item(
      user:, request: source, item: source.authorization_items.sole, duration: "permanent", breadth: "tool"
    )
    allow_any_instance_of(Permissions::AuthorizationDecision).to receive(:permission_descriptor).and_return(send_descriptor)
    allow(AppEvents).to receive(:broadcast)

    Permissions::AuthorizationDecision.new(
      request: source, item: source.authorization_items.sole, user:
    ).call(decision: "approved", smart: { duration: "permanent", breadth: "tool", digest: draft.preview.digest })

    expect(sibling.reload).to be_confirming
    expect(PermissionRule.count).to eq(1)
    expect(AuthorizedInvocation.count).to eq(2)
    expect(AppEvents).to have_received(:broadcast).with(
      hash_including(user:, resource: "chat", id: chat_session.id,
        changed: [ "pending_action_updated" ], payload: hash_including(pending_action_id: sibling.id, state: "confirming"))
    )
  end
end
