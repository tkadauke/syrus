require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe "API: /api/v1/admin/runtime_image_build_requests/:id/evidence", type: :request do
  let!(:admin) { Factories.user }
  let(:admin_token) { admin.generate_api_token! }
  let(:non_admin_token) { Factories.user.generate_api_token! }
  let(:namespace) { RuntimeImageNamespace.create!(name: "acme/widgets", owner_kind: "k", owner_ref: "1", provider_key: SyntheticRuntimeImageProvider.new.key) }
  let(:source) { RuntimeImages::Builds::SourceCapture.capture(kind: "git", ref: "git://repo", revision: "c" * 40) }
  let(:build_request) do
    RuntimeImages::Builds::Orchestrator.new.submit(namespace: namespace, source: source, recipe: {}, platform: "linux/amd64",
                                                  requester_kind: "t", requester_ref: "1")
  end

  before do
    attempt = build_request.attempts.create!(number: 1, state: "failed", started_at: Time.current)
    RuntimeImageBuildEvidence.create!(request: build_request, attempt: attempt, outcome: "failed", source_digest: build_request.source_digest,
                                      log: "line one\n", log_bytes: 9, finished_at: Time.current,
                                      destinations: [ { "host" => "github.com", "address" => "140.82.1.1", "count" => 1 } ])
  end

  it "returns the full restricted evidence to administrators" do
    get "/api/v1/admin/runtime_image_build_requests/#{build_request.id}/evidence", headers: { "Authorization" => "Bearer #{admin_token}" }
    body = JSON.parse(response.body)
    expect(response).to have_http_status(:ok)
    expect(body["source_digest"]).to eq(source.digest)
    expect(body["attempts"].first).to include("log" => "line one\n", "outcome" => "failed")
    expect(body["attempts"].first["destinations"].first["address"]).to eq("140.82.1.1")
  end

  it "401s without a token and 403s for non-admins" do
    get "/api/v1/admin/runtime_image_build_requests/#{build_request.id}/evidence"
    expect(response).to have_http_status(:unauthorized)
    get "/api/v1/admin/runtime_image_build_requests/#{build_request.id}/evidence", headers: { "Authorization" => "Bearer #{non_admin_token}" }
    expect(response).to have_http_status(:forbidden)
  end
end
