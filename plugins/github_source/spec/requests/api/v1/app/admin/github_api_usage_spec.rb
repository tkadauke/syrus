require "rails_helper"

RSpec.describe "GitHub API usage admin", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:non_admin) { Factories.user(admin: false) }

  before { admin }

  it "returns usage rollups for admins" do
    sign_in_as(admin)

    get "/api/v1/app/admin/github_api_usage"

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include("totals", "by_operation", "by_repository", "recent_rate_limits")
  end

  it "rejects non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/github_api_usage"

    expect(response).to have_http_status(:forbidden)
  end
end
