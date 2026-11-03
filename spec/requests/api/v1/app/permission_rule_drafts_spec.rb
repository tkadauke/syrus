require "rails_helper"

RSpec.describe "API: /api/v1/app/permission_rule_drafts", type: :request do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:role) { PermissionRule::SUBJECT_SELECTORS.fetch("interactive_chat").fetch(:role) }
  let(:descriptor) do
    Permissions::CapabilityDescriptor.new(
      capability: "syrus.deploys@v1", operation: "syrus.deploys/run@v1", effects: %i[internal_write], risk: :medium,
      requestable_roles: [ role ], defaults: { role => :ask }, maximum_autonomy: :permanent,
      authority_durations: %i[invocation chat_session job permanent], constraint_fields: { "branch" => :string },
      resource_scope: Permissions::ResourceScopeSchema.new(type: :none),
      classifier: ->(_arguments) { { operation: "syrus.deploys/run@v1", confidence: :certain } },
      fingerprint_normalizer: ->(arguments) { arguments }, redactor: ->(arguments) { arguments }
    )
  end
  let(:draft) do
    { policy: "allow", duration: "permanent", subject_selector_type: "interactive_chat",
      capability: "syrus.deploys@v1", operation: "syrus.deploys/run@v1" }
  end

  before do
    allow(Permissions::Catalog).to receive(:descriptors) { [ descriptor ] }
    sign_in_as(user)
  end

  it "exposes descriptor-supported options" do
    get "/api/v1/app/permission_rule_drafts/options", params: { capability: "syrus.deploys@v1", operation: "syrus.deploys/run@v1" }

    options = JSON.parse(response.body).fetch("options")
    expect(response).to have_http_status(:ok)
    expect(options).to include("authority_durations" => %w[chat_session job permanent], "permanent_allowed" => true,
      "maximum_autonomy" => "permanent", "constraint_fields" => { "branch" => "string" })
    expect(options.fetch("subject_types").pluck("type")).to include("interactive_chat", "agent", "workflow_role")
    expect(options.fetch("subject_types").pluck("type")).not_to include("eligible_roles")
  end

  it "previews then applies with the matching digest, and refuses a stale one" do
    post "/api/v1/app/permission_rule_drafts/preview", params: { draft: }, as: :json
    digest = JSON.parse(response.body).dig("preview", "digest")
    expect(response).to have_http_status(:ok)

    post "/api/v1/app/permission_rule_drafts/apply", params: { draft: draft.merge(duration: "permanent", rationale: "x"), digest: "stale" }, as: :json
    expect(response).to have_http_status(:conflict)
    expect(JSON.parse(response.body).dig("error", "code")).to eq("stale_permission_preview")
    expect(PermissionRule.count).to eq(0)

    post "/api/v1/app/permission_rule_drafts/apply", params: { draft:, digest: }, as: :json
    expect(response).to have_http_status(:created)
    expect(PermissionRule.where(owner_user: user).count).to eq(1)
  end

  it "returns validation errors for forbidden permanent authority" do
    allow(Permissions::Catalog).to receive(:descriptors) do
      [ Permissions::CapabilityDescriptor.new(**descriptor.to_h.merge(maximum_autonomy: :job, classifier: descriptor.classifier,
        fingerprint_normalizer: descriptor.fingerprint_normalizer, redactor: descriptor.redactor,
        resource_scope: descriptor.resource_scope, authority_durations: %i[invocation chat_session job])) ]
    end

    post "/api/v1/app/permission_rule_drafts/preview", params: { draft: }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body).dig("preview", "errors", 0, "code")).to eq("duration_not_offered")
  end

  it "derives a draft only from the signed-in user's own requests" do
    origin = ChatSession.create!(user:, title: "origin")
    foreign = ChatPendingAction.create!(request_kind: "authorization_request", user: Factories.user, repository:,
      origin: ChatSession.create!(user: Factories.user, title: "x"), subject: user, deduplication_key: "foreign-draft")
    item = foreign.authorization_items.create!(kind: "operation", capability: "syrus.deploys", operation: "syrus.deploys/run",
      operation_version: 1, resource_type: "none", resource_scope: {}, normalized_arguments: {},
      invocation_fingerprint: "fp", effects: [], policy_chain: [], requested_durations: [ "invocation" ])

    post "/api/v1/app/permission_rule_drafts/from_request", params: { request_id: foreign.id, item_id: item.id, duration: "job" }, as: :json

    expect(response).to have_http_status(:not_found)
    expect(origin).to be_persisted
  end
end
