require "rails_helper"

RSpec.describe "API: /api/v1/app/repositories/:repository_id/team_grants", type: :request do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner, owner: "acme", name: "widgets") }
  let(:team) { Team.create!(name: "Platform") }

  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/repositories/#{repository.id}/team_grants"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  describe "as a repository admin" do
    before { sign_in_as(owner) }

    it "lists existing team grants alongside memberships" do
      repository.team_repositories.create!(team: team, role: "write")

      get "/api/v1/app/repositories/#{repository.id}/team_grants"

      expect(response).to have_http_status(:ok)
      expect(parse_body["team_grants"]).to contain_exactly(
        include("role" => "write", "team" => include("id" => team.id, "name" => "Platform"))
      )
      expect(parse_body["memberships"]).to contain_exactly(include("user" => include("id" => owner.id)))
    end

    it "grants a team a role by name" do
      team

      expect {
        post "/api/v1/app/repositories/#{repository.id}/team_grants", params: { team_name: "Platform", role: "write" }, as: :json
      }.to change(TeamRepository, :count).by(1)

      expect(response).to have_http_status(:created)
      grant = repository.team_repositories.find_by(team: team)
      expect(grant.role).to eq("write")
    end

    it "looks up the team name case-insensitively" do
      team

      post "/api/v1/app/repositories/#{repository.id}/team_grants", params: { team_name: "platform", role: "read" }, as: :json

      expect(response).to have_http_status(:created)
      expect(repository.team_repositories.find_by(team: team)).to be_present
    end

    it "rejects an unknown team name" do
      post "/api/v1/app/repositories/#{repository.id}/team_grants", params: { team_name: "Nonexistent", role: "write" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects an invalid role" do
      team

      post "/api/v1/app/repositories/#{repository.id}/team_grants", params: { team_name: "Platform", role: "owner" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects granting the same team twice" do
      repository.team_repositories.create!(team: team, role: "read")

      post "/api/v1/app/repositories/#{repository.id}/team_grants", params: { team_name: "Platform", role: "write" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "message")).to include("already has a grant")
    end

    it "changes an existing grant's role" do
      grant = repository.team_repositories.create!(team: team, role: "read")

      patch "/api/v1/app/repositories/#{repository.id}/team_grants/#{grant.id}", params: { role: "admin" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(grant.reload.role).to eq("admin")
    end

    it "removes a grant" do
      grant = repository.team_repositories.create!(team: team, role: "read")

      expect {
        delete "/api/v1/app/repositories/#{repository.id}/team_grants/#{grant.id}"
      }.to change(TeamRepository, :count).by(-1)

      expect(response).to have_http_status(:ok)
      expect(TeamRepository.exists?(grant.id)).to be false
    end

    it "does not remove the repository membership -- a repo with zero grants stays direct-membership-only" do
      grant = repository.team_repositories.create!(team: team, role: "admin")

      delete "/api/v1/app/repositories/#{repository.id}/team_grants/#{grant.id}"

      expect(response).to have_http_status(:ok)
      expect(repository.repository_memberships.exists?(user: owner)).to be true
    end
  end

  describe "as a non-admin repository member" do
    it "404s for a write-tier member (team grants are admin-tier only)" do
      writer = Factories.user
      repository.repository_memberships.create!(user: writer, role: "write")
      sign_in_as(writer)

      get "/api/v1/app/repositories/#{repository.id}/team_grants"

      expect(response).to have_http_status(:not_found)
    end
  end
end
