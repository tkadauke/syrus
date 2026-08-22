require "rails_helper"
require "aws-sdk-s3"

RSpec.describe "API: /api/v1/app/admin/build_cache", type: :request do
  let(:admin) { Factories.user }
  let(:non_admin) do
    admin
    Factories.user
  end

  around do |example|
    old_bucket = ENV["SCCACHE_BUCKET"]
    ENV["SCCACHE_BUCKET"] = "syrus-build-cache-test"
    example.run
  ensure
    ENV["SCCACHE_BUCKET"] = old_bucket
    Admin::BuildCache::Client.client_factory = nil
  end

  def parse_body
    JSON.parse(response.body)
  end

  def stub_s3(objects: [])
    s3 = Aws::S3::Client.new(stub_responses: true, region: "auto")
    s3.stub_responses(:list_objects_v2, { is_truncated: false, contents: objects })
    s3.stub_responses(:delete_objects, {})
    Admin::BuildCache::Client.client_factory = -> { s3 }
    s3
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/admin/build_cache"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/build_cache"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  describe "GET show" do
    it "reports unconfigured when SCCACHE_BUCKET is unset" do
      ENV["SCCACHE_BUCKET"] = nil
      sign_in_as(admin)

      get "/api/v1/app/admin/build_cache"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["configured"]).to be(false)
      expect(body["stats"]).to be_nil
    end

    it "returns bucket stats when configured" do
      stub_s3(objects: [
        { key: "a", size: 100, last_modified: 3.days.ago },
        { key: "b", size: 200, last_modified: 1.day.ago }
      ])
      sign_in_as(admin)

      get "/api/v1/app/admin/build_cache"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["configured"]).to be(true)
      expect(body["stats"]).to include("object_count" => 2, "total_size_bytes" => 300)
      expect(body.dig("stats", "newest_object", "key")).to eq("b")
      expect(body["pending_request"]).to be_nil
    end
  end

  describe "POST clear_requests" do
    it "creates a pending request without touching the bucket" do
      s3 = stub_s3(objects: [ { key: "a", size: 100, last_modified: 3.days.ago } ])
      sign_in_as(admin)

      expect {
        post "/api/v1/app/admin/build_cache/clear_requests",
             params: { admin_build_cache_clear_request: { scope: "full", reason: "clearing out stale artifacts" } }
      }.to change(AdminBuildCacheClearRequest, :count).by(1)

      expect(response).to have_http_status(:created)
      body = parse_body
      expect(body.dig("pending_request", "scope")).to eq("full")
      expect(body.dig("pending_request", "reason")).to eq("clearing out stale artifacts")
      expect(body.dig("pending_request", "state")).to eq("pending")
      expect(s3.api_requests.map { |r| r[:operation_name] }).not_to include(:delete_objects)
    end

    it "rejects a request with no reason" do
      sign_in_as(admin)

      post "/api/v1/app/admin/build_cache/clear_requests",
           params: { admin_build_cache_clear_request: { scope: "full", reason: "" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("validation_failed")
    end

    it "rejects a second request while one is already pending" do
      sign_in_as(admin)
      AdminBuildCacheClearRequest.create!(user: admin, scope: "full", reason: "first request")

      post "/api/v1/app/admin/build_cache/clear_requests",
           params: { admin_build_cache_clear_request: { scope: "full", reason: "second request" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(AdminBuildCacheClearRequest.count).to eq(1)
    end
  end

  describe "POST clear_requests/:id/confirm" do
    it "executes the clear and records the outcome" do
      stub_s3(objects: [ { key: "a", size: 100, last_modified: 3.days.ago } ])
      sign_in_as(admin)
      request = AdminBuildCacheClearRequest.create!(user: admin, scope: "full", reason: "cleanup")

      expect {
        post "/api/v1/app/admin/build_cache/clear_requests/#{request.id}/confirm"
      }.to change(AdminAction, :count).by(1)

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["pending_request"]).to be_nil
      expect(body["recent_requests"].first).to include("id" => request.id, "state" => "confirmed")
      expect(request.reload.state).to eq("confirmed")
    end

    it "422s when the request is no longer pending" do
      stub_s3
      sign_in_as(admin)
      request = AdminBuildCacheClearRequest.create!(user: admin, scope: "full", reason: "cleanup")
      request.cancel!

      post "/api/v1/app/admin/build_cache/clear_requests/#{request.id}/confirm"

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("cannot_confirm")
    end
  end

  describe "POST clear_requests/:id/cancel" do
    it "cancels a pending request" do
      stub_s3
      sign_in_as(admin)
      request = AdminBuildCacheClearRequest.create!(user: admin, scope: "full", reason: "cleanup")

      post "/api/v1/app/admin/build_cache/clear_requests/#{request.id}/cancel"

      expect(response).to have_http_status(:ok)
      expect(request.reload.state).to eq("cancelled")
    end
  end
end
