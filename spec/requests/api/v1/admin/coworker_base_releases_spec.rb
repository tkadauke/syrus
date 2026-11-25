require "rails_helper"
require "support/coworker_base_release_helpers"

RSpec.describe "API: /api/v1/admin/coworker_base_releases", type: :request do
  include CoworkerBaseReleaseHelpers

  let!(:admin) { Factories.user }
  let(:auth) { { "Authorization" => "Bearer #{admin.generate_api_token!}" } }
  let(:plain_auth) { { "Authorization" => "Bearer #{Factories.user.generate_api_token!}" } }

  before do
    allow(BaseRebuildDiscoveryJob).to receive(:perform_later)
    allow(RuntimeImages::BaseReleases).to receive(:new).and_return(base_releases)
  end

  it "401s without a token and 403s for non-admins" do
    get "/api/v1/admin/coworker_base_releases"
    expect(response).to have_http_status(:unauthorized)
    get "/api/v1/admin/coworker_base_releases", headers: plain_auth
    expect(response).to have_http_status(:forbidden)
    post "/api/v1/admin/coworker_base_releases/#{candidate.id}/promote", headers: plain_auth
    expect(response).to have_http_status(:forbidden)
    expect(CoworkerBaseRelease.active).to be_empty
  end

  it "lists releases with launch state, rollback targets, and environments needing rebuild" do
    active_base
    get "/api/v1/admin/coworker_base_releases", headers: auth
    body = JSON.parse(response.body)
    expect(body.keys).to include("platforms", "candidates", "revoked", "needing_rebuild", "releases")
    amd = body["platforms"].find { |p| p["platform"] == "linux/amd64" }
    expect(amd).to include("state" => "ready")
    expect(amd["active"]).to include("status" => "active")
  end

  it "promotes a candidate and records the acting admin" do
    release = candidate
    post "/api/v1/admin/coworker_base_releases/#{release.id}/promote", headers: auth
    expect(response).to have_http_status(:ok)
    expect(release.reload).to be_active
    expect(release.promoted_by).to eq("user:#{admin.id}")
  end

  it "422s when promotion is refused" do
    release = active_base
    post "/api/v1/admin/coworker_base_releases/#{release.id}/promote", headers: auth
    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body).dig("error", "code")).to eq("not_a_candidate")
  end

  it "rolls back and revokes" do
    first = active_base
    second = active_base
    post "/api/v1/admin/coworker_base_releases/rollback", params: { platform: "linux/amd64" }, headers: auth
    expect(response).to have_http_status(:ok)
    expect(first.reload).to be_active

    post "/api/v1/admin/coworker_base_releases/#{first.id}/revoke", params: { reason: "CVE", severity: "severe" }, headers: auth
    expect(response).to have_http_status(:ok)
    expect(first.reload).to have_attributes(status: "revoked", revocation_severity: "severe")
    expect(second.reload).to be_retired
  end

  it "422s when the rollback release belongs to another platform" do
    arm = active_base(platform: "linux/arm64")
    active_base(platform: "linux/arm64")
    post "/api/v1/admin/coworker_base_releases/rollback", params: { platform: "linux/amd64", release_id: arm.id }, headers: auth
    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body).dig("error", "code")).to eq("platform_mismatch")
    expect(arm.reload).to be_retired
  end

  it "422s on a revoke without a reason or with a bad severity" do
    release = active_base
    post "/api/v1/admin/coworker_base_releases/#{release.id}/revoke", params: { reason: "" }, headers: auth
    expect(response).to have_http_status(:unprocessable_content)
    post "/api/v1/admin/coworker_base_releases/#{release.id}/revoke", params: { reason: "x", severity: "mild" }, headers: auth
    expect(response).to have_http_status(:unprocessable_content)
    expect(release.reload).to be_active
  end

  it "sets and rejects support deadlines" do
    release = active_base
    post "/api/v1/admin/coworker_base_releases/#{release.id}/support", params: { supported_until: 3.days.from_now.iso8601 }, headers: auth
    expect(response).to have_http_status(:ok)
    expect(release.reload.supported_until).to be_present
    post "/api/v1/admin/coworker_base_releases/#{release.id}/support", params: { supported_until: "not a time" }, headers: auth
    expect(response).to have_http_status(:unprocessable_content)
  end
end
