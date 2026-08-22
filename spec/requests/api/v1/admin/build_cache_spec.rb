require "rails_helper"
require "aws-sdk-s3"

RSpec.describe "API: /api/v1/admin/build_cache", type: :request do
  let(:admin) { Factories.user }
  let(:admin_token) { admin.generate_api_token! }
  def auth = { "Authorization" => "Bearer #{admin_token}" }
  def parse_body = JSON.parse(response.body)

  around do |example|
    old_bucket = ENV["SCCACHE_BUCKET"]
    ENV["SCCACHE_BUCKET"] = "syrus-build-cache-test"
    example.run
  ensure
    ENV["SCCACHE_BUCKET"] = old_bucket
    Admin::BuildCache::Client.client_factory = nil
  end

  it "401s without a token" do
    get "/api/v1/admin/build_cache"

    expect(response).to have_http_status(:unauthorized)
  end

  it "returns bucket footprint stats" do
    s3 = Aws::S3::Client.new(stub_responses: true, region: "auto")
    s3.stub_responses(:list_objects_v2, {
      is_truncated: false,
      contents: [ { key: "a", size: 100, last_modified: 3.days.ago } ]
    })
    Admin::BuildCache::Client.client_factory = -> { s3 }

    get "/api/v1/admin/build_cache", headers: auth

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["configured"]).to be(true)
    expect(body["stats"]).to include("object_count" => 1, "total_size_bytes" => 100)
  end
end
