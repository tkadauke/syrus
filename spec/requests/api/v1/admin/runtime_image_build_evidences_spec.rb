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

  it "returns exact policy remediation only through the restricted endpoint" do
    provider = SyntheticRuntimeImageProvider.new
    service = RuntimeImages::Service.new(provider: provider)
    image = service.publish(namespace: namespace, source_kind: "test", source_ref: "revision", platform: "linux/amd64", payload: "image")
    verification = image.runtime_image_verification_attempts.create!(number: 1, image_digest: image.digest, state: "rejected",
      decision: "rejected", policy_snapshot: {}, policy_digest: "sha256:" + ("a" * 64), started_at: Time.current, finished_at: Time.current)
    policy_evidence = verification.create_policy_evidence!(image_digest: image.digest,
      safe_summary: { "finding_count" => 1, "codes" => { "secret_detected" => 1 } },
      report_digest: "sha256:" + ("b" * 64), scanned_at: Time.current)
    policy_evidence.report.attach(io: StringIO.new(JSON.generate("secret_scan" => { "location" => "Dockerfile:9" })),
                                  filename: "policy.json", content_type: "application/json")
    build_request.update_columns(state: "succeeded", finished_at: Time.current)
    RuntimeImageBuildResult.create!(request: build_request, runtime_image: image, outcome: "succeeded", finished_at: Time.current)

    get "/api/v1/admin/runtime_image_build_requests/#{build_request.id}/evidence", headers: { "Authorization" => "Bearer #{admin_token}" }

    policy = JSON.parse(response.body).fetch("verification_policy")
    expect(policy.fetch("safe_summary")).to eq("finding_count" => 1, "codes" => { "secret_detected" => 1 })
    expect(policy.dig("report", "secret_scan", "location")).to eq("Dockerfile:9")
  end
end
