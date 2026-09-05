require "rails_helper"

RSpec.describe "Agent Activity filter API", type: :request do
  def parse_body = JSON.parse(response.body)

  it "records agent_activity (operator surface) filter usage" do
    user = Factories.user
    repo = Factories.repository(user:, owner: "tkadauke", name: "syrus")
    sign_in_as(user)

    post "/api/v1/app/filters/usage",
         params: {
           surface: "agent_activity",
           subject: "agent_activity",
           filter: {
             "and" => [
               { "field" => "repository_id", "op" => "is", "value" => repo.id.to_s }
             ]
           }
         }

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("recorded")).to be(true)
    expect(FilterUsage.find_by!(user:, surface: "agent_activity", subject: "agent_activity").use_count).to eq(1)
  end

  it "records agent_activity_admin (admin surface) filter usage separately from the operator surface" do
    user = Factories.user(admin: true)
    sign_in_as(user)

    post "/api/v1/app/filters/usage",
         params: {
           surface: "agent_activity_admin",
           subject: "agent_activity",
           filter: { "and" => [ { "field" => "status", "op" => "is_one_of", "value" => [ "running" ] } ] }
         }

    expect(response).to have_http_status(:ok)
    expect(FilterUsage.find_by!(user:, surface: "agent_activity_admin", subject: "agent_activity").use_count).to eq(1)
  end

  it "suggests complete agent_activity filters from FK value matches" do
    user = Factories.user
    repo = Factories.repository(user:, owner: "tkadauke", name: "syrus")
    sign_in_as(user)

    get "/api/v1/app/filters/suggestions", params: { surface: "agent_activity", subject: "agent_activity", q: "syrus" }

    expect(response).to have_http_status(:ok)
    labels = parse_body.fetch("suggestions").map { |suggestion| suggestion.fetch("label") }
    expect(labels).to include("Repository is #{repo.owner}/#{repo.name}")
  end
end
