require "rails_helper"

RSpec.describe "API: repository throughput metrics", type: :request do
  it "serves metrics for a repository the user can access" do
    user = Factories.user
    repository = Factories.repository(user: user)
    sign_in_as(user)

    get "/api/v1/app/repositories/#{repository.id}/throughput_metrics"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["repository_id"]).to eq(repository.id)
    expect(response.parsed_body["version"]).to eq(Throughput::MetricContract::VERSION)
  end

  it "scopes lookup to repositories the signed-in user can access" do
    Factories.user(admin: true)
    other = Factories.repository(user: Factories.user)
    viewer = Factories.user
    sign_in_as(viewer)

    expect(Repository.accessible_to(viewer)).not_to include(other)
  end
end
