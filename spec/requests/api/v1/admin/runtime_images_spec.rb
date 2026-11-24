require "rails_helper"

RSpec.describe "API: /api/v1/admin/runtime_images", type: :request do
  let(:admin) { Factories.user }
  let(:admin_token) { admin.generate_api_token! }
  def auth = { "Authorization" => "Bearer #{admin_token}" }

  it "401s without a token" do
    get "/api/v1/admin/runtime_images"
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns the diagnostics snapshot" do
    get "/api/v1/admin/runtime_images", headers: auth
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).keys).to include("checks", "images", "retained", "cleanup_failures", "pulls", "cache", "recent_audit")
  end

  it "queues a reconciliation pass" do
    expect { post "/api/v1/admin/runtime_images/reconcile", headers: auth }.to have_enqueued_job(RuntimeImageReconcileJob)
    expect(response).to have_http_status(:accepted)
  end
end
