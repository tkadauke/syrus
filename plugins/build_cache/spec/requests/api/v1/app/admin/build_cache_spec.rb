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
    BuildCache::Client.client_factory = nil
  end

  def parse_body
    JSON.parse(response.body)
  end

  def stub_s3(objects: [])
    s3 = Aws::S3::Client.new(stub_responses: true, region: "auto")
    s3.stub_responses(:list_objects_v2, { is_truncated: false, contents: objects })
    s3.stub_responses(:delete_objects, {})
    BuildCache::Client.client_factory = -> { s3 }
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

      get "/api/v1/app/admin/build_cache", params: { include_stats: "true" }

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

      get "/api/v1/app/admin/build_cache", params: { include_stats: "true" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["configured"]).to be(true)
      expect(body["stats"]).to include("object_count" => 2, "total_size_bytes" => 300)
      expect(body.dig("stats", "newest_object", "key")).to eq("b")
      expect(body["pending_request"]).to be_nil
    end

    it "can skip bucket stats so the admin page loads without scanning S3" do
      s3 = stub_s3(objects: [ { key: "a", size: 100, last_modified: 3.days.ago } ])
      sign_in_as(admin)

      get "/api/v1/app/admin/build_cache"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["configured"]).to be(true)
      expect(body["stats"]).to be_nil
      expect(s3.api_requests.map { |request| request[:operation_name] }).not_to include(:list_objects_v2)
    end

    it "returns FilterBar schema fields and filters clear request history" do
      stub_s3
      sign_in_as(admin)
      wanted = BuildCache::ClearRequest.create!(user: admin, scope: "partial", older_than_days: 30, reason: "stale compiler objects")
      wanted.update!(state: "confirmed", confirmed_at: 5.minutes.ago, result: { "deleted_count" => 2, "bytes_freed" => 1234, "truncated" => false })
      BuildCache::ClearRequest.create!(user: admin, scope: "full", reason: "different cleanup").update!(state: "cancelled", cancelled_at: 5.minutes.ago)

      get "/api/v1/app/admin/build_cache", params: {
        state: "confirmed",
        scope: "partial",
        older_than_days: "30",
        reason: "compiler",
        user_id: admin.id,
        result_status: "present"
      }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["filter_schema"].map { |field| field["field"] }).to include(
        "state",
        "scope",
        "older_than_days",
        "reason",
        "user_id",
        "confirmed_since",
        "cancelled_since",
        "created_since",
        "updated_since",
        "result_status"
      )
      expect(body["recent_requests"].map { |request| request["id"] }).to eq([ wanted.id ])
      expect(body["recent_requests"].first).to include(
        "older_than_days" => 30,
        "result_status" => "present",
        "updated_at" => be_present
      )
    end

    it "loads bucket stats from a separate endpoint" do
      stub_s3(objects: [ { key: "a", size: 100, last_modified: 3.days.ago } ])
      sign_in_as(admin)

      get "/api/v1/app/admin/build_cache/stats"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("stats", "object_count")).to eq(1)
    end
  end

  describe "POST clear_requests" do
    it "creates a pending request without touching the bucket" do
      s3 = stub_s3(objects: [ { key: "a", size: 100, last_modified: 3.days.ago } ])
      sign_in_as(admin)

      expect {
        post "/api/v1/app/admin/build_cache/clear_requests",
             params: { admin_build_cache_clear_request: { scope: "full", reason: "clearing out stale artifacts" } }
      }.to change(BuildCache::ClearRequest, :count).by(1)

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
      BuildCache::ClearRequest.create!(user: admin, scope: "full", reason: "first request")

      post "/api/v1/app/admin/build_cache/clear_requests",
           params: { admin_build_cache_clear_request: { scope: "full", reason: "second request" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(BuildCache::ClearRequest.count).to eq(1)
    end
  end

  describe "POST clear_requests/:id/confirm" do
    it "executes the clear and records the outcome" do
      stub_s3(objects: [ { key: "a", size: 100, last_modified: 3.days.ago } ])
      sign_in_as(admin)
      request = BuildCache::ClearRequest.create!(user: admin, scope: "full", reason: "cleanup")

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
      request = BuildCache::ClearRequest.create!(user: admin, scope: "full", reason: "cleanup")
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
      request = BuildCache::ClearRequest.create!(user: admin, scope: "full", reason: "cleanup")

      post "/api/v1/app/admin/build_cache/clear_requests/#{request.id}/cancel"

      expect(response).to have_http_status(:ok)
      expect(request.reload.state).to eq("cancelled")
    end
  end
end
