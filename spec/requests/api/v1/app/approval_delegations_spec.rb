require "rails_helper"

RSpec.describe "API: /api/v1/app/approval_delegations", type: :request do
  let(:user) { Factories.user }
  let(:provider) do
    Class.new do
      def self.provider_key = "reviewer"
      def self.display_name = "Reviewer"
      def self.data_sharing = "Evidence is sent to Reviewer Cloud."
      def self.default_guidance = "Be conservative."
    end
  end
  let(:capability) { Permissions::Catalog.descriptors.first.capability }
  let(:params) do
    { approval_delegation: { provider_key: "reviewer", capability:, resource_type: "job", resource_scope: { job_id: [ 1 ] } } }
  end

  before { sign_in_as(user) unless RSpec.current_example.metadata[:skip_sign_in] }

  def stub_providers(*list)
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:approval_provider).and_return(list)
  end

  it "is disabled with no provider and refuses to create a delegation" do
    stub_providers

    get "/api/v1/app/approval_delegations"
    expect(JSON.parse(response.body)).to include("enabled" => false, "providers" => [], "delegations" => [], "plugins" => be_an(Array),
      "can_manage_plugins" => user.admin?)
    expect(JSON.parse(response.body).dig("human_only", "effects")).to include("financial", "privilege_change")

    post "/api/v1/app/approval_delegations", params: params, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(user.approval_provider_delegations).to be_empty
  end

  it "creates a bounded delegation, discloses the provider, and revokes immediately" do
    stub_providers(provider)

    post "/api/v1/app/approval_delegations", params: params, as: :json
    expect(response).to have_http_status(:created)
    id = JSON.parse(response.body).dig("delegation", "id")

    get "/api/v1/app/approval_delegations"
    payload = JSON.parse(response.body)
    expect(payload).to include("enabled" => true)
    expect(payload.dig("providers", 0)).to include("data_sharing" => "Evidence is sent to Reviewer Cloud.", "default_guidance" => "Be conservative.")
    expect(payload.dig("delegations", 0)).to include("status" => "active", "excluded_effects" => include("financial"))

    post "/api/v1/app/approval_delegations/#{id}/revoke"
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig("delegation", "status")).to eq("revoked")
    expect(ApprovalProviderDelegation.find(id).revoked_by_user).to eq(user)
  end

  it "rejects unbounded scope and unknown capabilities" do
    stub_providers(provider)

    post "/api/v1/app/approval_delegations", params: { approval_delegation: params[:approval_delegation].merge(resource_scope: {}) }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    post "/api/v1/app/approval_delegations", params: { approval_delegation: params[:approval_delegation].merge(capability: "nope@v1") }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "does not expose or revoke another user's delegation" do
    stub_providers(provider)
    other = ApprovalProviderDelegation.create!(owner_user: Factories.user, provider_key: "reviewer", capability:, resource_type: "job", resource_scope: { job_id: [ 1 ] })

    get "/api/v1/app/approval_delegations"
    expect(JSON.parse(response.body).fetch("delegations")).to be_empty
    post "/api/v1/app/approval_delegations/#{other.id}/revoke"
    expect(response).to have_http_status(:not_found)
    expect(other.reload).to be_active
  end

  it "lists the owner's AI decisions from the request transition history" do
    stub_providers(provider)
    delegation = ApprovalProviderDelegation.create!(owner_user: user, provider_key: "reviewer", capability:, resource_type: "job", resource_scope: { job_id: [ 1 ] })
    request = ChatPendingAction.create!(request_kind: "authorization_request", user:, subject: user, origin: user,
      deduplication_key: "ai-history", purpose: "Cancel a stuck job")
    request.transitions.create!(event_type: Permissions::ApprovalProviderLifecycle::EVALUATED_EVENT, to_state: "pending",
      actor: delegation, metadata: { "outcome" => "deny", "approval_provider" => { "decision" => { "rationale" => "Too broad" } } })

    get "/api/v1/app/approval_delegations"
    expect(JSON.parse(response.body).fetch("history")).to contain_exactly(
      include("outcome" => "deny", "rationale" => "Too broad", "purpose" => "Cancel a stuck job", "delegation_id" => delegation.id)
    )
  end

  it "refuses agent invocation credentials so an AI principal cannot delegate to itself", :skip_sign_in do
    repository = Factories.repository(user: user)
    job = Factories.job_with_run(repository:, user:, run_attrs: { state: "running" })
    token = McpInvocationContext.issue_for_app_run(job.runs.first, expires_in: 5.minutes)

    post "/api/v1/app/approval_delegations", params: params, as: :json, headers: { "Authorization" => "Bearer #{token}" }
    expect(response).to have_http_status(:forbidden)
    expect(ApprovalProviderDelegation.count).to eq(0)
  end

  it "keeps every active delegation visible and revocable beyond the history window" do
    stub_providers(provider)
    oldest = ApprovalProviderDelegation.create!(owner_user: user, provider_key: "reviewer", capability:, resource_type: "job",
      resource_scope: { job_id: [ 0 ] }, created_at: 1.year.ago)
    stub_const("Permissions::ApprovalDelegationPayload::HISTORY_LIMIT", 2)
    3.times do |i|
      ApprovalProviderDelegation.create!(owner_user: user, provider_key: "reviewer", capability:, resource_type: "job",
        resource_scope: { job_id: [ i + 1 ] })
    end

    get "/api/v1/app/approval_delegations"
    expect(JSON.parse(response.body).fetch("delegations").pluck("id")).to include(oldest.id)

    post "/api/v1/app/approval_delegations/#{oldest.id}/revoke"
    expect(JSON.parse(response.body).dig("delegation", "id")).to eq(oldest.id)
    expect(oldest.reload).not_to be_active
  end
end
