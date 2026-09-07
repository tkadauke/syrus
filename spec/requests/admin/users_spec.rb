require "rails_helper"

RSpec.describe "Admin users", type: :request do
  let!(:admin) { Factories.user }
  let(:non_admin) { Factories.user }

  describe "GET /admin/users" do
    it "blocks non-admins" do
      sign_in_as(non_admin)

      get "/admin/users"

      expect(response).to redirect_to(root_path)
    end

    it "serves the React users shell for admins" do
      sign_in_as(admin)

      get "/admin/users"

      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end

  describe "GET /admin/users/:id" do
    it "serves the React user detail shell for admins" do
      sign_in_as(admin)
      target = Factories.user(email_address: "target@example.com")

      get "/admin/users/#{target.id}"

      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end

  it "serves the SPA shell for retired legacy HTML user GET paths instead of 404ing" do
    sign_in_as(admin)

    [ "/admin/users/legacy", "/admin/users/legacy/1" ].each do |path|
      get path

      expect(response).to have_http_status(:ok), "expected #{path} to serve the SPA shell"
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end

  it "does not route the retired legacy HTML user endpoints" do
    expect {
      Rails.application.routes.recognize_path("/admin/users/1/pause_scheduling", method: :post)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/admin/users/1/unpause_scheduling", method: :post)
    }.to raise_error(ActionController::RoutingError)
  end
end
