require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/permission_parity", type: :request do
  let!(:admin) { Factories.user(admin: true) }

  it "requires an admin and returns the parity diagnostic payload" do
    get "/api/v1/app/admin/permission_parity"
    expect(response).to have_http_status(:unauthorized)

    allow(Admin::PermissionParityDiagnostics).to receive(:new)
      .with(limit: "25").and_return(instance_double(Admin::PermissionParityDiagnostics,
        as_json: { total: 3, mismatches: 2, evaluation_failures: 1 }))
    sign_in_as(admin)
    get "/api/v1/app/admin/permission_parity", params: { limit: 25 }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include("total" => 3, "mismatches" => 2)
  end
end
