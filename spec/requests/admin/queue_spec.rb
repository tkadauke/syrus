require "rails_helper"

RSpec.describe "Admin queue inspector", type: :request do
  let(:admin) { Factories.user }
  let(:non_admin) { admin; Factories.user }

  describe "GET /admin/queue" do
    it "redirects unauthenticated users" do
      get "/admin/queue"

      expect(response).to redirect_to(new_session_path).or redirect_to(new_user_path)
    end

    it "blocks non-admins" do
      sign_in_as(non_admin)

      get "/admin/queue"

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to match(/admin/i)
    end

    it "serves the React queue shell for admins" do
      sign_in_as(admin)

      get "/admin/queue"

      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end

    it "serves nested queue tabs through the React queue shell" do
      sign_in_as(admin)

      get "/admin/queue/active"

      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end

  it "serves the SPA shell for retired legacy HTML queue GET paths instead of 404ing" do
    sign_in_as(admin)

    [ "/admin/queue/legacy", "/admin/queue/legacy/active" ].each do |path|
      get path

      expect(response).to have_http_status(:ok), "expected #{path} to serve the SPA shell"
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end

  it "does not route the retired legacy HTML queue endpoints" do
    expect {
      Rails.application.routes.recognize_path("/admin/queue/reap_stale_runs", method: :post)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/admin/queue/legacy/reap_stale_runs", method: :post)
    }.to raise_error(ActionController::RoutingError)
  end
end
