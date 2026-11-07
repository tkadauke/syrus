require "rails_helper"

RSpec.describe "API: /api/v1/app/teams", type: :request do
  # The first User created in the process is auto-promoted to admin
  # (User#promote_first_user_to_admin) — create the admin first so the
  # other users are guaranteed non-admin regardless of reference order.
  let(:admin) { Factories.user(admin: true) }
  let(:owner) { admin && Factories.user }
  let(:outsider) { admin && Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  def capture_sql
    queries = []
    callback = ->(_name, _started, _finished, _id, payload) { queries << payload[:sql].to_s unless payload[:name].to_s.match?(/\ASCHEMA|TRANSACTION\z/) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/teams"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  describe "index" do
    it "lists only teams the current user belongs to" do
      mine = Team.create!(name: "Platform")
      mine.team_memberships.create!(user: owner, role: "member")
      Team.create!(name: "Growth")
      sign_in_as(owner)

      get "/api/v1/app/teams"

      expect(response).to have_http_status(:ok)
      expect(parse_body["teams"].map { |t| t["id"] }).to contain_exactly(mine.id)
    end

    it "lists every team for a global admin" do
      Team.create!(name: "Platform")
      Team.create!(name: "Growth")
      sign_in_as(admin)

      get "/api/v1/app/teams"

      expect(parse_body["teams"].size).to eq(2)
    end

    it "loads team counts with two grouped queries" do
      3.times do |index|
        team = Team.create!(name: "Team #{index}")
        team.team_memberships.create!(user: owner, role: "member")
      end
      sign_in_as(owner)

      queries = capture_sql { get "/api/v1/app/teams" }

      expect(queries.grep(/COUNT\(\*\).*GROUP BY.*team_id/i).size).to eq(2)
    end
  end

  describe "create" do
    before { sign_in_as(owner) }

    it "creates a team and makes the creator its owner" do
      expect {
        post "/api/v1/app/teams", params: { team: { name: "Platform" } }, as: :json
      }.to change(Team, :count).by(1)

      expect(response).to have_http_status(:created)
      team = Team.find_by(name: "Platform")
      expect(team.owned_by?(owner)).to be true
      expect(parse_body.keys).to contain_exactly("message", "team")
    end

    it "rejects a blank name" do
      post "/api/v1/app/teams", params: { team: { name: "" } }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "localizes validation errors in German" do
      owner.update!(locale: "de")

      post "/api/v1/app/teams", params: { team: { name: "" } }, as: :json

      expect(parse_body.dig("error", "message")).to eq("Der Name darf nicht leer sein.")
    end

    it "rejects a duplicate name" do
      Team.create!(name: "Platform")

      post "/api/v1/app/teams", params: { team: { name: "Platform" } }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "show" do
    it "is visible to a team member" do
      team = Team.create!(name: "Platform")
      team.team_memberships.create!(user: owner, role: "member")
      sign_in_as(owner)

      get "/api/v1/app/teams/#{team.id}"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("team", "id")).to eq(team.id)
    end

    it "paginates memberships" do
      team = Team.create!(name: "Platform")
      team.team_memberships.create!(user: owner, role: "member")
      50.times do |index|
        user = User.create!(email_address: "member#{index}@example.com", password: "password123")
        team.team_memberships.create!(user: user, role: "member")
      end
      sign_in_as(owner)

      get "/api/v1/app/teams/#{team.id}", params: { membership_page: 2 }

      expect(parse_body["memberships"].size).to eq(1)
      expect(parse_body["membership_pagination"]).to include("page" => 2, "per_page" => 50, "total" => 51, "total_pages" => 2)
    end

    it "404s for a non-member" do
      team = Team.create!(name: "Platform")
      sign_in_as(outsider)

      get "/api/v1/app/teams/#{team.id}"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "update" do
    it "allows the team owner to rename" do
      team = Team.create!(name: "Platform")
      team.team_memberships.create!(user: owner, role: "owner")
      sign_in_as(owner)

      patch "/api/v1/app/teams/#{team.id}", params: { team: { name: "Core Platform" } }, as: :json

      expect(response).to have_http_status(:ok)
      expect(team.reload.name).to eq("Core Platform")
    end

    it "forbids a non-owner member from renaming" do
      team = Team.create!(name: "Platform")
      team.team_memberships.create!(user: owner, role: "member")
      sign_in_as(owner)

      patch "/api/v1/app/teams/#{team.id}", params: { team: { name: "Core Platform" } }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(team.reload.name).to eq("Platform")
    end

    it "allows a global admin to rename regardless of membership" do
      team = Team.create!(name: "Platform")
      sign_in_as(admin)

      patch "/api/v1/app/teams/#{team.id}", params: { team: { name: "Core Platform" } }, as: :json

      expect(response).to have_http_status(:ok)
      expect(team.reload.name).to eq("Core Platform")
    end
  end

  describe "destroy" do
    it "allows the team owner to delete" do
      team = Team.create!(name: "Platform")
      team.team_memberships.create!(user: owner, role: "owner")
      sign_in_as(owner)

      expect {
        delete "/api/v1/app/teams/#{team.id}"
      }.to change(Team, :count).by(-1)

      expect(response).to have_http_status(:ok)
      expect(parse_body.keys).to contain_exactly("message")
    end

    it "forbids a non-owner member from deleting" do
      team = Team.create!(name: "Platform")
      team.team_memberships.create!(user: owner, role: "member")
      sign_in_as(owner)

      delete "/api/v1/app/teams/#{team.id}"

      expect(response).to have_http_status(:forbidden)
      expect(Team.exists?(team.id)).to be true
    end
  end
end
