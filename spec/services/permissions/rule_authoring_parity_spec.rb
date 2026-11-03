require "rails_helper"

# An equivalent rule authored through the Permissions Hub, an authorization
# card's Customize path and a confirmed grant_permission tool call must
# serialize, validate, evaluate, audit and revoke identically.
RSpec.describe "Permission rule authoring parity" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:chat_role) { PermissionRule::SUBJECT_SELECTORS.fetch("interactive_chat").fetch(:role) }
  let(:schema) do
    Permissions::ResourceScopeSchema.new(
      type: :repository,
      normalize: ->(scope, context:) { { repository_id: Integer(scope.to_h.stringify_keys.fetch("repository_id")) } },
      compare: ->(left, right, context:) { left == right ? :equal : :disjoint },
      label: ->(scope, context:) { "repository ##{scope.fetch('repository_id')}" }
    )
  end
  let(:descriptor) do
    Permissions::CapabilityDescriptor.new(
      capability: "syrus.deploys@v1", operation: "syrus.deploys/run@v1", effects: %i[internal_write], risk: :medium,
      requestable_roles: [ chat_role ], defaults: { chat_role => :ask }, maximum_autonomy: :permanent,
      authority_durations: %i[invocation chat_session job permanent], resource_scope: schema,
      classifier: ->(_arguments) { { operation: "syrus.deploys/run@v1", confidence: :certain } },
      fingerprint_normalizer: ->(arguments) { arguments }, redactor: ->(arguments) { arguments }
    )
  end
  let(:scope) { { "repository_id" => repository.id } }
  let(:attributes) do
    { "policy" => "allow", "duration" => "permanent", "subject_selector_type" => "interactive_chat",
      "capability" => "syrus.deploys@v1", "operation" => "syrus.deploys/run@v1", "resource_scope" => scope }
  end

  before { allow(Permissions::Catalog).to receive(:descriptors) { [ descriptor ] } }

  def hub_rule
    draft = Permissions::RuleDraft.new(user:, attributes:)
    draft.apply!(digest: draft.preview.digest, actor: user)
  end

  def card_rule
    request = ChatPendingAction.create!(
      request_kind: "authorization_request", user:, repository:, chat_session: ChatSession.create!(user:, title: "c"),
      origin: ChatSession.create!(user:, title: "o"), subject: user, runtime_role: chat_role, deduplication_key: SecureRandom.hex(4)
    )
    item = request.authorization_items.create!(
      kind: "operation", capability: "syrus.deploys", capability_version: 1, operation: "syrus.deploys/run",
      operation_version: 1, resource_type: "repository", resource_scope: scope, normalized_arguments: {},
      invocation_fingerprint: "fp", effects: [], policy_chain: [], requested_durations: [ "invocation" ]
    )
    draft = Permissions::RuleDraft.from_request_item(user:, request:, item:, duration: "permanent")
    draft.apply!(digest: draft.preview.digest, actor: user)
  end

  def tool_rule
    chat = ChatSession.create!(user:, title: "t")
    action = chat.pending_actions.create!(action: "grant_permission", payload: attributes.except("policy", "duration").merge("role" => chat_role))
    PendingActions::GrantPermission.new(action).execute
  end

  def comparable(rule)
    rule.attributes.slice(*PermissionRule::AUDITED_ATTRIBUTES).except("created_at", "updated_at", "provenance", "source")
  end

  def evaluation
    Permissions::Management.new(user).explain(
      descriptor:, role: chat_role, resource_scope: scope, arguments: {}, context: { user:, subject_selector_type: "interactive_chat" }
    ).policy.to_s
  end

  it "serializes, audits, evaluates and revokes the same rule from every surface" do
    results = { hub: :hub_rule, card: :card_rule, tool: :tool_rule }.transform_values do |builder|
      rule = send(builder)
      snapshot = { attributes: comparable(rule), audit: rule.audit_events.pluck(:event_type), evaluated: evaluation }
      Permissions::Management.new(user).revoke_rule!(rule.id, actor: user)
      snapshot.merge(revoked: rule.reload.revoked_at.present?, revoked_audit: rule.audit_events.pluck(:event_type), after_revoke: evaluation)
    end

    expect(results[:hub][:attributes]).to include("policy" => "allow", "resource_scope" => { "repository_id" => repository.id })
    expect(results[:card]).to eq(results[:hub])
    expect(results[:tool]).to eq(results[:hub])
    expect(results[:hub]).to include(audit: [ "created" ], evaluated: "allow", revoked: true, after_revoke: "ask")
  end

  it "previews a confirmed management call with the same readable summary as the Hub draft" do
    hub = Permissions::RuleDraft.new(user:, attributes:).preview
    tool = Permissions::RuleDraft.from_management_payload(
      user:, action: "grant_permission", payload: attributes.except("policy", "duration").merge("role" => chat_role)
    ).preview

    expect(tool.summary).to eq(hub.summary)
    expect(tool.examples).to eq(hub.examples)
    expect(hub.examples[:matches].first).to include("syrus.deploys/run@v1", "repository ##{repository.id}")
    expect(hub.examples[:non_matches]).to include(a_string_matching(/outside repository/))
  end

  it "previews deny management calls as a deny draft and ignores unsupported actions" do
    deny = Permissions::RuleDraft.from_management_payload(user:, action: "deny_permission", payload: attributes.except("policy", "duration")).preview
    expect(deny.draft).to include(policy: "deny", duration: "permanent")
    expect(Permissions::RuleDraft.from_management_payload(user:, action: "revoke_permission", payload: {})).to be_nil
  end
end
