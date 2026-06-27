require "rails_helper"

RSpec.describe "Admin features", type: :request do
  let(:admin) { Factories.user }
  let(:non_admin) do
    admin
    Factories.user
  end

  describe "GET /admin/features" do
    it "routes to the SPA shell" do
      expect(Rails.application.routes.recognize_path("/admin/features", method: :get)).to include(
        controller: "spa",
        action: "show"
      )
    end

    it "blocks non-admins" do
      sign_in_as(non_admin)

      get "/admin/features"

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to match(/admin/i)
    end

    it "serves the React features shell for admins" do
      sign_in_as(admin)

      get "/admin/features"

      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end
end
