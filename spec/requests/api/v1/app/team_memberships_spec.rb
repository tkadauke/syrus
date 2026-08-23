require "rails_helper"

RSpec.describe "API: /api/v1/app/teams/:team_id/memberships", type: :request do
  let(:owner) { Factories.user }
  let(:team) { Team.create!(name: "Platform").tap { |t| t.team_memberships.create!(user: owner, role: "owner") } }

  def parse_body
    JSON.parse(response.body)
  end

  describe "as a team owner" do
    before { sign_in_as(owner) }

    it "adds a user by email at the chosen role" do
      team_id = team.id
      invitee = Factories.user(email_address: "invitee@example.com")

      expect {
        post "/api/v1/app/teams/#{team_id}/memberships", params: { email: "invitee@example.com", role: "member" }, as: :json
      }.to change(TeamMembership, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(team.team_memberships.find_by(user: invitee).role).to eq("member")
    end

    it "rejects an unknown email" do
      post "/api/v1/app/teams/#{team.id}/memberships", params: { email: "nobody@example.com", role: "member" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects an invalid role" do
      Factories.user(email_address: "invitee@example.com")

      post "/api/v1/app/teams/#{team.id}/memberships", params: { email: "invitee@example.com", role: "admin" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "changes an existing member's role" do
      member = Factories.user
      membership = team.team_memberships.create!(user: member, role: "member")

      patch "/api/v1/app/teams/#{team.id}/memberships/#{membership.id}", params: { role: "owner" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(membership.reload.role).to eq("owner")
    end

    it "removes a member" do
      member = Factories.user
      membership = team.team_memberships.create!(user: member, role: "member")
      membership_id = membership.id

      expect {
        delete "/api/v1/app/teams/#{team.id}/memberships/#{membership_id}"
      }.to change(TeamMembership, :count).by(-1)

      expect(response).to have_http_status(:ok)
    end

    it "refuses to remove the last owner" do
      membership = team.team_memberships.find_by(user: owner)

      delete "/api/v1/app/teams/#{team.id}/memberships/#{membership.id}"

      expect(response).to have_http_status(:unprocessable_content)
      expect(TeamMembership.exists?(membership.id)).to be true
    end

    it "refuses to demote the last owner" do
      membership = team.team_memberships.find_by(user: owner)

      patch "/api/v1/app/teams/#{team.id}/memberships/#{membership.id}", params: { role: "member" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(membership.reload.role).to eq("owner")
    end
  end

  describe "as a non-owner team member" do
    it "forbids adding members" do
      team_id = team.id
      member = Factories.user
      team.team_memberships.create!(user: member, role: "member")
      sign_in_as(member)

      post "/api/v1/app/teams/#{team_id}/memberships", params: { email: "invitee@example.com", role: "member" }, as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end
end
