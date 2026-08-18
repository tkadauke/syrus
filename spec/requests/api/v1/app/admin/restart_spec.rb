require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/restart", type: :request do
  let!(:admin) { Factories.user }
  let(:non_admin) { Factories.user }

  let(:cache_backend) { ActiveSupport::Cache::MemoryStore.new }

  before do
    # Test env's Rails.cache is :null_store; delegate to a real per-example
    # MemoryStore so the poison-pill write/read is observable.
    allow(Rails.cache).to receive(:write) { |*args, **kwargs| cache_backend.write(*args, **kwargs) }
    allow(Rails.cache).to receive(:read) { |*args, **kwargs| cache_backend.read(*args, **kwargs) }
  end

  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    post "/api/v1/app/admin/restart", params: { component: "web" }

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    post "/api/v1/app/admin/restart", params: { component: "web" }

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "202s for component web and logs the admin action with source app" do
    sign_in_as(admin)

    expect {
      post "/api/v1/app/admin/restart", params: { component: "web" }
    }.to change { AdminAction.where(action: "restart").count }.by(1)

    expect(response).to have_http_status(:accepted)
    expect(parse_body).to include("initiated" => true, "component" => "web")
    expect(AdminAction.last.params["source"]).to eq("app")
    expect(Rails.cache.read("syrus:restart_web")).to be_a(Float)
  end

  it "409s for worker with active runs and no force" do
    sign_in_as(admin)
    Factories.job

    post "/api/v1/app/admin/restart", params: { component: "worker" }

    expect(response).to have_http_status(:conflict)
    expect(parse_body).to include("initiated" => false, "active_runs" => 1)
  end

  it "202s for worker with active runs when forced" do
    sign_in_as(admin)
    Factories.job

    post "/api/v1/app/admin/restart", params: { component: "worker", force: true }

    expect(response).to have_http_status(:accepted)
    expect(parse_body).to include("initiated" => true, "active_runs" => 1)
  end

  it "202s for component all and writes both poison-pill keys" do
    sign_in_as(admin)

    post "/api/v1/app/admin/restart", params: { component: "all" }

    expect(response).to have_http_status(:accepted)
    expect(Rails.cache.read("syrus:restart_web")).to be_a(Float)
    expect(Rails.cache.read("syrus:restart_worker")).to be_a(Float)
  end
end
