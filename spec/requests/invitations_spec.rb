require "rails_helper"

RSpec.describe "Invitations", type: :request do
  let(:admin) { Factories.user }
  let(:non_admin) { Factories.user }

  it "requires authentication" do
    admin

    get invitations_path

    expect(response).to redirect_to(new_session_path)
  end

  context "as a non-admin" do
    before { admin; sign_in_as(non_admin) }

    it "blocks the React invitations shell" do
      get invitations_path

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to match(/Admin access/)
    end
  end

  context "as an admin" do
    before { admin; sign_in_as(admin) }

    it "serves the React invitations shell" do
      get invitations_path

      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end

    it "does not route the retired legacy HTML invitation endpoints" do
      expect {
        Rails.application.routes.recognize_path("/invitations", method: :post)
      }.to raise_error(ActionController::RoutingError)
      expect {
        Rails.application.routes.recognize_path("/invitations/1", method: :delete)
      }.to raise_error(ActionController::RoutingError)
    end

    it "serves the SPA shell for the retired legacy HTML invitation GET path instead of 404ing" do
      get "/invitations/legacy"

      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end
end
