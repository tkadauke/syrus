require "rails_helper"

RSpec.describe "API: /api/v1/app/linear", type: :request do
  let(:user) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  describe "GET /api/v1/app/linear/teams" do
    it "401s when signed out" do
      get "/api/v1/app/linear/teams", params: { api_key: "lin_api_test" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns an error when api_key param is missing" do
      sign_in_as(user)
      get "/api/v1/app/linear/teams"
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns an error when api_key param is blank" do
      sign_in_as(user)
      get "/api/v1/app/linear/teams", params: { api_key: "" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns teams from LinearClient" do
      sign_in_as(user)
      teams = [ { "id" => "team-uuid-1", "name" => "Engineering" }, { "id" => "team-uuid-2", "name" => "Design" } ]
      allow_any_instance_of(LinearClient).to receive(:teams).and_return(teams)

      get "/api/v1/app/linear/teams", params: { api_key: "lin_api_valid" }

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

      get "/api/v1/app/linear/teams", params: { api_key: "lin_api_valid" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["teams"]).to eq([])
    end

    it "returns a 422 when LinearClient raises (e.g. invalid key)" do
      sign_in_as(user)
      allow_any_instance_of(LinearClient).to receive(:teams).and_raise("Linear API error: unauthorized")

      get "/api/v1/app/linear/teams", params: { api_key: "lin_api_bad" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "message")).to include("unauthorized")
    end
  end
end
