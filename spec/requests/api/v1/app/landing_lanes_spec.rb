require "rails_helper"

RSpec.describe "Landing lanes API", type: :request do
  let(:user) { Factories.user }
  let!(:repository) { Factories.repository(user:, landing_concurrency: 2) }

  before { sign_in_as(user) }

  it "returns every visible repository with all configured slots" do
    get "/api/v1/app/landing_lanes"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body).to include("estimate_kind" => "best_case")
    expect(body.fetch("repositories")).to include(
      include("id" => repository.id, "landing_concurrency" => 2, "busy_lane_count" => 0,
        "lanes" => [ include("number" => 1, "empty" => true), include("number" => 2, "empty" => true) ])
    )
  end
end
