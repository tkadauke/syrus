require "rails_helper"

RSpec.describe "Repository documents", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before { sign_in_as(user) }

  describe "GET /repositories/:repository_id/documents" do
    it "serves the React repository documents shell" do
      get repository_documents_path(repo, frame: 1)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="syrus-spa-root"')
    end

    it "serves the SPA shell for the retired legacy HTML document GET path instead of 404ing" do
      get "/repositories/#{repo.id}/documents/legacy"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="syrus-spa-root"')
    end

    it "does not route the retired legacy HTML document endpoints" do
      expect {
        Rails.application.routes.recognize_path("/repositories/#{repo.id}/documents/legacy", method: :post)
      }.to raise_error(ActionController::RoutingError)
      expect {
        Rails.application.routes.recognize_path("/repositories/#{repo.id}/documents", method: :post)
      }.to raise_error(ActionController::RoutingError)
      expect {
        Rails.application.routes.recognize_path("/documents/1", method: :delete)
      }.to raise_error(ActionController::RoutingError)
    end
  end
end
