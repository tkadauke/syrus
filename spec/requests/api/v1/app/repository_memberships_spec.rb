require "rails_helper"

RSpec.describe "API: /api/v1/app/repositories/:repository_id/memberships", type: :request do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner, owner: "acme", name: "widgets") }

  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/repositories/#{repository.id}/memberships"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  describe "as a repository admin" do
    before { sign_in_as(owner) }

    it "lists the seeded owner membership" do
      get "/api/v1/app/repositories/#{repository.id}/memberships"

      expect(response).to have_http_status(:ok)
      expect(parse_body["memberships"]).to contain_exactly(
        include("role" => "admin", "user" => include("id" => owner.id))
      )
      expect(parse_body.dig("repository", "id")).to eq(repository.id)
      expect(parse_body["tabs"].map { |tab| tab["key"] }).to include("members")
    end

    it "adds a user by email at the chosen role" do
      repository
      invitee = Factories.user(email_address: "invitee@example.com")

      expect {
        post "/api/v1/app/repositories/#{repository.id}/memberships", params: { email: "invitee@example.com", role: "write" }, as: :json
      }.to change(RepositoryMembership, :count).by(1)

      expect(response).to have_http_status(:created)
      membership = repository.repository_memberships.find_by(user: invitee)
      expect(membership.role).to eq("write")
    end

    it "rejects an unknown email" do
      post "/api/v1/app/repositories/#{repository.id}/memberships", params: { email: "nobody@example.com", role: "write" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects an invalid role" do
      Factories.user(email_address: "invitee@example.com")

      post "/api/v1/app/repositories/#{repository.id}/memberships", params: { email: "invitee@example.com", role: "owner" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects adding a user who is already a member" do
      post "/api/v1/app/repositories/#{repository.id}/memberships", params: { email: owner.email_address, role: "write" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "message")).to include("already a member")
    end

    it "changes an existing member's role" do
      member = Factories.user
      membership = repository.repository_memberships.create!(user: member, role: "read")

      patch "/api/v1/app/repositories/#{repository.id}/memberships/#{membership.id}", params: { role: "write" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(membership.reload.role).to eq("write")
    end

    it "removes a member" do
      member = Factories.user
      membership = repository.repository_memberships.create!(user: member, role: "read")

      expect {
        delete "/api/v1/app/repositories/#{repository.id}/memberships/#{membership.id}"
      }.to change(RepositoryMembership, :count).by(-1)

      expect(response).to have_http_status(:ok)
      expect(RepositoryMembership.exists?(membership.id)).to be false
    end

    it "refuses to remove the last admin" do
      membership = repository.repository_memberships.find_by(user: owner)

      delete "/api/v1/app/repositories/#{repository.id}/memberships/#{membership.id}"

      expect(response).to have_http_status(:unprocessable_content)
      expect(RepositoryMembership.exists?(membership.id)).to be true
    end

    it "refuses to demote the last admin" do
      membership = repository.repository_memberships.find_by(user: owner)

      patch "/api/v1/app/repositories/#{repository.id}/memberships/#{membership.id}", params: { role: "write" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(membership.reload.role).to eq("admin")
    end

    it "allows demoting an admin when another admin remains" do
      other_admin = Factories.user
      repository.repository_memberships.create!(user: other_admin, role: "admin")
      membership = repository.repository_memberships.find_by(user: owner)

      patch "/api/v1/app/repositories/#{repository.id}/memberships/#{membership.id}", params: { role: "write" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(membership.reload.role).to eq("write")
    end
  end

  describe "as a non-admin repository member" do
    it "404s for a write-tier member (memberships are admin-tier only)" do
      writer = Factories.user
      repository.repository_memberships.create!(user: writer, role: "write")
      sign_in_as(writer)

      get "/api/v1/app/repositories/#{repository.id}/memberships"

      expect(response).to have_http_status(:not_found)
    end

    it "404s for a user with no membership on the repository" do
      outsider = Factories.user
      sign_in_as(outsider)

      get "/api/v1/app/repositories/#{repository.id}/memberships"

      expect(response).to have_http_status(:not_found)
    end
  end
end
