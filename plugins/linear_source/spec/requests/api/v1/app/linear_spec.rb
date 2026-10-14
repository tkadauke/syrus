require "rails_helper"

RSpec.describe "API: /api/v1/app/linear", type: :request do
  let(:user) { Factories.user }

  before { PluginRecord.find_by!(name: "linear_source").update!(enabled: true) }

  def parse_body
    JSON.parse(response.body)
  end

  describe "POST /api/v1/app/linear/teams" do
    it "401s when signed out" do
      post "/api/v1/app/linear/teams", params: { api_key: "lin_api_test" }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns an error when api_key param is missing" do
      sign_in_as(user)
      post "/api/v1/app/linear/teams", as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns an error when api_key param is blank" do
      sign_in_as(user)
      post "/api/v1/app/linear/teams", params: { api_key: "" }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns teams from LinearClient" do
      sign_in_as(user)
      teams = [ { "id" => "team-uuid-1", "name" => "Engineering" }, { "id" => "team-uuid-2", "name" => "Design" } ]
      allow_any_instance_of(LinearClient).to receive(:teams).and_return(teams)

      post "/api/v1/app/linear/teams", params: { api_key: "lin_api_valid" }, as: :json

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["teams"]).to eq([
        { "id" => "team-uuid-1", "name" => "Engineering" },
        { "id" => "team-uuid-2", "name" => "Design" }
      ])
    end

    it "returns an empty teams array when LinearClient returns []" do
      sign_in_as(user)
      allow_any_instance_of(LinearClient).to receive(:teams).and_return([])

      post "/api/v1/app/linear/teams", params: { api_key: "lin_api_valid" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body["teams"]).to eq([])
    end

    it "returns a 422 when LinearClient raises (e.g. invalid key)" do
      sign_in_as(user)
      allow_any_instance_of(LinearClient).to receive(:teams).and_raise("Linear API error: unauthorized")

      post "/api/v1/app/linear/teams", params: { api_key: "lin_api_bad" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "message")).to include("unauthorized")
    end

    it "does not expose the teams lookup over GET with query-string credentials" do
      sign_in_as(user)

      get "/api/v1/app/linear/teams", params: { api_key: "lin_api_secret" }

      expect(response).to have_http_status(:not_found)
    end
  end
end
