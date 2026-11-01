require "rails_helper"

RSpec.describe "API: /api/v1/admin/permission_parity", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let!(:admin_token) { admin.generate_api_token! }

  it "requires an admin API token and returns the parity diagnostic payload" do
    get "/api/v1/admin/permission_parity"
    expect(response).to have_http_status(:unauthorized)

    allow(Admin::PermissionParityDiagnostics).to receive(:new)
      .with(limit: nil).and_return(instance_double(Admin::PermissionParityDiagnostics,
        as_json: { total: 1, mismatches: 1, evaluation_failures: 0 }))
    get "/api/v1/admin/permission_parity",
      headers: { "Authorization" => "Bearer #{admin_token}" }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include("total" => 1, "mismatches" => 1)
  end
end
