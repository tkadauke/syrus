require "rails_helper"

RSpec.describe "API: /api/v1/admin/restart", type: :request do
  let!(:admin) { Factories.user }
  let!(:admin_token) { admin.generate_api_token! }
  let(:non_admin) { Factories.user }
  let(:non_admin_token) { non_admin.generate_api_token! }

  let(:cache_backend) { ActiveSupport::Cache::MemoryStore.new }

  before do
    # Test env's Rails.cache is :null_store; delegate to a real per-example
    # MemoryStore so the poison-pill write/read is observable.
    allow(Rails.cache).to receive(:write) { |*args, **kwargs| cache_backend.write(*args, **kwargs) }
    allow(Rails.cache).to receive(:read) { |*args, **kwargs| cache_backend.read(*args, **kwargs) }
  end

  def auth(token = admin_token) = { "Authorization" => "Bearer #{token}" }
  def parse_body = JSON.parse(response.body)

  it "202s for component web with no active-run check" do
    post "/api/v1/admin/restart", params: { component: "web" }, headers: auth

    expect(response).to have_http_status(:accepted)
    expect(parse_body).to include("initiated" => true, "component" => "web")
    expect(Rails.cache.read("syrus:restart_web")).to be_a(Float)
  end

  it "409s for component worker with active runs and no force" do
    Factories.job

    post "/api/v1/admin/restart", params: { component: "worker" }, headers: auth

    expect(response).to have_http_status(:conflict)
    expect(parse_body).to include("initiated" => false, "active_runs" => 1)
    expect(Rails.cache.read("syrus:restart_worker")).to be_nil
  end

  it "202s for component worker with active runs and force true" do
    Factories.job

    post "/api/v1/admin/restart", params: { component: "worker", force: true }, headers: auth

    expect(response).to have_http_status(:accepted)
    expect(parse_body).to include("initiated" => true, "active_runs" => 1)
    expect(Rails.cache.read("syrus:restart_worker")).to be_a(Float)
  end

  it "writes Rails.cache with the correct key and a recent timestamp" do
    freeze_time do
      post "/api/v1/admin/restart", params: { component: "web" }, headers: auth

      expect(Rails.cache.read("syrus:restart_web")).to eq(Time.now.utc.to_f)
    end
  end

  it "401s for unauthenticated requests" do
    post "/api/v1/admin/restart", params: { component: "web" }

    expect(response).to have_http_status(:unauthorized)
  end

  it "403s for non-admin users" do
    post "/api/v1/admin/restart", params: { component: "web" }, headers: auth(non_admin_token)

    expect(response).to have_http_status(:forbidden)
  end

  it "400s for an unknown component" do
    post "/api/v1/admin/restart", params: { component: "database" }, headers: auth

    expect(response).to have_http_status(:bad_request)
  end
end
