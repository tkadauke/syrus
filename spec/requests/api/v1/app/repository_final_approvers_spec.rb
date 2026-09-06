require "rails_helper"

RSpec.describe "API: /api/v1/app/repositories/:repository_id/final_approvers", type: :request do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner, owner: "acme", name: "widgets", review_policy: "final_say") }

  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/repositories/#{repository.id}/final_approvers"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  describe "as a repository admin" do
    before { sign_in_as(owner) }

    it "lists no final approvers by default" do
      get "/api/v1/app/repositories/#{repository.id}/final_approvers"

      expect(response).to have_http_status(:ok)
      expect(parse_body["final_approvers"]).to eq([])
    end

    it "adds a user by email as a final approver" do
      approver = Factories.user(email_address: "approver@example.com")

      expect {
        post "/api/v1/app/repositories/#{repository.id}/final_approvers", params: { email: "approver@example.com" }, as: :json
      }.to change(RepositoryFinalApprover, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(repository.final_approver_ids).to eq([ approver.id ])
      expect(parse_body["final_approvers"]).to contain_exactly(
        include("user" => include("id" => approver.id, "email_address" => "approver@example.com"))
      )
    end

    it "rejects an unknown email" do
      post "/api/v1/app/repositories/#{repository.id}/final_approvers", params: { email: "nobody@example.com" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects adding a user who is already a final approver" do
      approver = Factories.user(email_address: "approver@example.com")
      repository.repository_final_approvers.create!(user: approver)

      post "/api/v1/app/repositories/#{repository.id}/final_approvers", params: { email: "approver@example.com" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "message")).to include("already a final approver")
    end

    it "removes a final approver" do
      approver = Factories.user(email_address: "approver@example.com")
      final_approver = repository.repository_final_approvers.create!(user: approver)

      expect {
        delete "/api/v1/app/repositories/#{repository.id}/final_approvers/#{final_approver.id}"
      }.to change(RepositoryFinalApprover, :count).by(-1)

      expect(response).to have_http_status(:ok)
      expect(RepositoryFinalApprover.exists?(final_approver.id)).to be false
    end
  end

  describe "as a non-admin repository member" do
    it "404s for a write-tier member (final approver management is admin-tier only)" do
      writer = Factories.user
      repository.repository_memberships.create!(user: writer, role: "write")
      sign_in_as(writer)

      get "/api/v1/app/repositories/#{repository.id}/final_approvers"

      expect(response).to have_http_status(:not_found)
    end

    it "404s for a user with no membership on the repository" do
      outsider = Factories.user
      sign_in_as(outsider)

      get "/api/v1/app/repositories/#{repository.id}/final_approvers"

      expect(response).to have_http_status(:not_found)
    end
  end
end
