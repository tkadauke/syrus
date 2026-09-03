require "rails_helper"

# Uses the linear_source plugin as its concrete registered input source:
# core ships the InputSource model and API, but no source type of its own.
RSpec.describe "API: /api/v1/app/input_sources", type: :request, requires_plugin: "linear_source" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def parse_body
    JSON.parse(response.body)
  end

  before do
    PluginRecord.find_by!(name: "linear_source").update!(enabled: true)
  end

  it "401s when signed out" do
    get "/api/v1/app/repositories/#{repository.id}/input_sources/linear"
    expect(response).to have_http_status(:unauthorized)
  end

  it "shows an existing source by registered type key" do
    sign_in_as(user)
    source = InputSources::Linear.create!(
      repository: repository,
      user: user,
      polling_enabled: true,
      config: { "team_id" => "TEAM-123", "label_filter" => "syrus" },
      credentials: { "api_key" => "lin_api_test" }
    )

    get "/api/v1/app/repositories/#{repository.id}/input_sources/linear"

    expect(response).to have_http_status(:ok)
    expect(parse_body["input_source"]).to include(
      "id" => source.id,
      "type" => "InputSources::Linear",
      "type_key" => "linear",
      "polling_enabled" => true,
      "values" => include("team_id" => "TEAM-123", "label_filter" => "syrus", "api_key" => "")
    )
  end

  it "creates and validates a source from schema-scoped values" do
    sign_in_as(user)
    allow_any_instance_of(LinearClient).to receive(:viewer).and_return({ "id" => "user-1" })
    allow_any_instance_of(LinearClient).to receive(:teams).and_return([ { "id" => "TEAM-123", "name" => "Engineering" } ])

    expect {
      patch "/api/v1/app/repositories/#{repository.id}/input_sources/linear", params: {
        input_source: {
          polling_enabled: true,
          values: {
            api_key: "lin_api_test",
            team_id: "TEAM-123",
            label_filter: "syrus"
          }
        }
      }
    }.to change(InputSources::Linear, :count).by(1)

    expect(response).to have_http_status(:ok)
    source = InputSources::Linear.last
    expect(source.config).to include("team_id" => "TEAM-123", "label_filter" => "syrus")
    expect(source.credentials).to include("api_key" => "lin_api_test")
    expect(parse_body["message"]).to include("Linear")
  end

  it "does not resolve unregistered type keys through constantize" do
    sign_in_as(user)

    get "/api/v1/app/repositories/#{repository.id}/input_sources/application_record"

    expect(response).to have_http_status(:not_found)
  end
end
