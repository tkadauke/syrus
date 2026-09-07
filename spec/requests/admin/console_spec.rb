require "rails_helper"

RSpec.describe "Admin operator console", type: :request do
  let(:admin) { Factories.user }
  let(:non_admin) { admin; Factories.user }

  describe "GET /admin/console" do
    it "blocks non-admins" do
      sign_in_as(non_admin)

      get "/admin/console"

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to match(/admin/i)
    end

    it "serves the React console shell for admins" do
      sign_in_as(admin)

      get "/admin/console"

      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end

  it "serves the SPA shell for the retired legacy HTML console GET path instead of 404ing" do
    sign_in_as(admin)

    get "/admin/console/legacy"

    expect(response).to be_successful
    expect(response.body).to include('id="syrus-spa-root"')
  end

  it "does not route the retired legacy HTML console endpoints" do
    expect {
      Rails.application.routes.recognize_path("/admin/console/pause_polling", method: :post)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/admin/console/unpause_polling", method: :post)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/admin/console/pause_runs", method: :post)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/admin/console/unpause_runs", method: :post)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/admin/console/clear_github_cache", method: :post)
    }.to raise_error(ActionController::RoutingError)
  end
end
