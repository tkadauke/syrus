require "rails_helper"
require "support/synthetic_runtime_image_provider"

RSpec.describe "API: /api/v1/admin/runtime_image_build_requests", type: :request do
  let!(:admin) { Factories.user }
  let(:admin_token) { admin.generate_api_token! }
  let(:non_admin_token) { Factories.user.generate_api_token! }
  let(:namespace) { RuntimeImageNamespace.create!(name: "acme/widgets", owner_kind: "k", owner_ref: "1", provider_key: SyntheticRuntimeImageProvider.new.key) }
  let(:orchestrator) { RuntimeImages::Builds::Orchestrator.new }

  def submit(revision)
    source = RuntimeImages::Builds::SourceCapture.capture(kind: "git", ref: "git://repo", revision: revision)
    orchestrator.submit(namespace: namespace, source: source, recipe: {}, platform: "linux/amd64", requester_kind: "t", requester_ref: "1")
  end

  def auth(token = admin_token) = { "Authorization" => "Bearer #{token}" }

  it "lists requests with their current attempt and result, filtered by state" do
    queued = submit("a" * 40)
    failed = submit("b" * 40)
    failed.update!(state: "building")
    failed.attempts.create!(number: 1, state: "building", started_at: Time.current)
    orchestrator.fail_attempt(failed.attempts.first, code: "network_denied", detail: "blocked", retryable: false)

    get "/api/v1/admin/runtime_image_build_requests", headers: auth
    expect(response).to have_http_status(:ok)
    ids = JSON.parse(response.body)["requests"].map { |r| r["id"] }
    expect(ids).to eq([ failed.id, queued.id ])

    get "/api/v1/admin/runtime_image_build_requests", params: { state: "failed" }, headers: auth
    body = JSON.parse(response.body)["requests"]
    expect(body.size).to eq(1)
    expect(body.first).to include("state" => "failed")
    expect(body.first["result"]).to include("error_code" => "network_denied")
    expect(body.first["current_attempt"]).to include("number" => 1, "error_code" => "network_denied")
  end

  it "cancels a queued request" do
    request = submit("c" * 40)
    post "/api/v1/admin/runtime_image_build_requests/#{request.id}/cancel", params: { reason: "stop" }, headers: auth
    expect(response).to have_http_status(:accepted)
    expect(request.reload).to be_canceled
    expect(request.cancel_reason).to eq("stop")
  end

  it "flags an in-flight request for cancellation" do
    request = submit("d" * 40)
    RuntimeImages::Builds.builder = double("builder")
    orchestrator.claim_next
    post "/api/v1/admin/runtime_image_build_requests/#{request.id}/cancel", headers: auth
    expect(JSON.parse(response.body)).to include("cancel_requested" => true, "state" => "building")
  ensure
    RuntimeImages::Builds.builder = nil
  end

  it "rejects non-administrators" do
    get "/api/v1/admin/runtime_image_build_requests", headers: auth(non_admin_token)
    expect(response).to have_http_status(:forbidden).or have_http_status(:unauthorized)
    post "/api/v1/admin/runtime_image_build_requests/1/cancel", headers: auth(non_admin_token)
    expect(response.status).to be_in([ 401, 403 ])
  end

  it "exposes build health on the runtime image diagnostics endpoint" do
    submit("e" * 40)
    get "/api/v1/admin/runtime_images", headers: auth
    expect(JSON.parse(response.body).dig("builds", "requests")).to eq("queued" => 1)
  end
end
