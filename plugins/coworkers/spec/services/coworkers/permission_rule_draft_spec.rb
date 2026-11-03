require "rails_helper"

RSpec.describe Permissions::RuleDraft, "with exact coworker subjects" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:chat_session) { ChatSession.create!(user:, title: "Coworker chat") }
  let(:role) { AgentRole::COWORKER }
  let(:coworker) { Coworkers::Coworker.create!(owner_user: user, name: "Maya", handle: "maya", workspace_repo: "git@example.com:ws.git") }
  let(:descriptor) do
    Permissions::CapabilityDescriptor.new(
      capability: "syrus.deploys@v1", operation: "syrus.deploys/run@v1", effects: %i[internal_write], risk: :medium,
      requestable_roles: [ role ], defaults: { role => :ask }, maximum_autonomy: :job,
      authority_durations: %i[invocation chat_session job],
      resource_scope: Permissions::ResourceScopeSchema.new(type: :none),
      classifier: ->(_arguments) { { operation: "syrus.deploys/run@v1", confidence: :certain } },
      fingerprint_normalizer: ->(arguments) { arguments }, redactor: ->(arguments) { arguments }
    )
  end
  let(:request) do
    ChatPendingAction.create!(request_kind: "authorization_request", user:, repository:, chat_session:, origin: chat_session,
      subject: coworker, runtime_role: role, deduplication_key: "coworker-draft")
  end
  let(:item) do
    request.authorization_items.create!(
      kind: "operation", capability: "syrus.deploys", capability_version: 1, operation: "syrus.deploys/run",
      operation_version: 1, resource_type: "none", resource_scope: {}, normalized_arguments: {},
      invocation_fingerprint: "fp", effects: [], policy_chain: [], requested_durations: [ "invocation" ]
    )
  end

  before { allow(Permissions::Catalog).to receive(:descriptors) { [ descriptor ] } }

  it "drafts and applies authority for exactly the requesting coworker" do
    draft = described_class.from_request_item(user:, request:, item:, duration: "chat_session")
    preview = draft.preview

    expect(preview).to be_valid
    expect(preview.draft[:subject]).to include(type: "agent", id: coworker.id.to_s, subject_type: "Coworkers::Coworker")
    lease = draft.apply!(digest: preview.digest, actor: user)
    expect(lease).to have_attributes(subject_selector_type: "agent", subject_selector_id: coworker.id.to_s, chat_session:)
  end

  it "rejects a coworker owned by another user" do
    other = Coworkers::Coworker.create!(owner_user: Factories.user, name: "Other", handle: "other-one", workspace_repo: "git@example.com:o.git")
    draft = described_class.new(user:, attributes: {
      "duration" => "chat_session", "chat_session_id" => chat_session.id, "subject_selector_type" => "agent",
      "subject_selector_id" => other.id, "subject_type" => "Coworkers::Coworker", "role" => role,
      "capability" => "syrus.deploys@v1", "operation" => "syrus.deploys/run@v1"
    })

    expect(draft.preview.errors.pluck(:code)).to eq([ "unknown_subject" ])
  end
end
