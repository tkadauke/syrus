require "rails_helper"

RSpec.describe "API: permission-management pending action previews", type: :request do
  let(:user) { Factories.user }
  let(:role) { PermissionRule::SUBJECT_SELECTORS.fetch("interactive_chat").fetch(:role) }
  let(:descriptor) do
    Permissions::CapabilityDescriptor.new(
      capability: "syrus.deploys@v1", operation: "syrus.deploys/run@v1", effects: %i[internal_write], risk: :medium,
      requestable_roles: [ role ], defaults: { role => :ask }, maximum_autonomy: :permanent,
      authority_durations: %i[invocation chat_session job permanent],
      resource_scope: Permissions::ResourceScopeSchema.new(type: :none),
      classifier: ->(_arguments) { { operation: "syrus.deploys/run@v1", confidence: :certain } },
      fingerprint_normalizer: ->(arguments) { arguments }, redactor: ->(arguments) { arguments }
    )
  end
  let(:chat) { ChatSession.create!(user:, title: "Permissions") }
  let(:payload) { { "role" => role, "subject_selector_type" => "interactive_chat", "capability" => "syrus.deploys@v1", "operation" => "syrus.deploys/run@v1" } }

  before do
    allow(Permissions::Catalog).to receive(:descriptors) { [ descriptor ] }
    sign_in_as(user)
  end

  def serialized_action
    get "/api/v1/app/chats/#{chat.id}"
    JSON.parse(response.body).fetch("pending_actions").find { |action| action["id"] == @action.id }
  end

  it "serializes the canonical readable preview for a pending grant_permission call" do
    @action = chat.pending_actions.create!(action: "grant_permission", payload:)

    preview = serialized_action.fetch("permission_rule_preview")

    expect(preview).to include("valid" => true)
    expect(preview.dig("draft", "policy")).to eq("allow")
    expect(preview.fetch("summary").fetch("allows").first).to include("syrus.deploys/run@v1")
    expect(preview.dig("examples", "non_matches")).not_to be_empty
  end

  it "previews deny calls as deny drafts and omits previews for unrelated actions" do
    @action = chat.pending_actions.create!(action: "deny_permission", payload:)
    expect(serialized_action.dig("permission_rule_preview", "draft", "policy")).to eq("deny")

    @action = chat.pending_actions.create!(action: "cancel_job", payload: { "job_id" => Factories.job_record(user:).id })
    expect(serialized_action).not_to have_key("permission_rule_preview")
  end

  it "does not break the card when the payload cannot be previewed" do
    @action = chat.pending_actions.create!(action: "grant_permission", payload: payload.merge("capability" => "nope@v1"))

    expect(serialized_action.fetch("permission_rule_preview")).to include("valid" => false)
  end
end
