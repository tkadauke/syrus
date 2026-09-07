require "rails_helper"

RSpec.describe "Settings", type: :request do
  let(:admin) { Factories.user }
  let(:non_admin) { Factories.user }

  describe "GET /settings" do
    it "requires authentication" do
      admin  # force a User to exist; first-run setup redirects to new_user instead
      get settings_path
      expect(response).to redirect_to(new_session_path)
    end

    context "as a non-admin" do
      before { admin; sign_in_as(non_admin) }

      it "serves the React credentials shell as an intentional alias" do
        get settings_path

        expect(response).to be_successful
        expect(response.body).to include('id="syrus-spa-root"')
        expect(response.body).to include('id="syrus-bootstrap-data"')
        expect(response.body).to include(non_admin.email_address)
      end
    end

    context "as an admin" do
      before { sign_in_as(admin) }

      it "serves the React credentials shell as an intentional alias" do
        get settings_path

        expect(response).to be_successful
        expect(response.body).to include('id="syrus-spa-root"')
        expect(response.body).to include('id="syrus-bootstrap-data"')
        expect(response.body).to include(admin.email_address)
      end
    end
  end

  describe "GET /settings/edit" do
    it "requires authentication" do
      admin  # force a User to exist; first-run setup redirects to new_user instead
      get edit_settings_path
      expect(response).to redirect_to(new_session_path)
    end

    context "as a non-admin" do
      before { admin; sign_in_as(non_admin) }

      it "blocks edit" do
        get edit_settings_path
        expect(response).to redirect_to(root_path)
      end
    end

    context "as an admin" do
      before { sign_in_as(admin) }

      it "serves the React app settings shell" do
        get edit_settings_path
        expect(response).to be_successful
        expect(response.body).to include('id="syrus-spa-root"')
      end

      it "does not route the retired legacy HTML settings endpoints" do
        expect {
          Rails.application.routes.recognize_path("/settings", method: :patch)
        }.to raise_error(ActionController::RoutingError)
        expect {
          Rails.application.routes.recognize_path("/settings/legacy", method: :patch)
        }.to raise_error(ActionController::RoutingError)
      end

      it "serves the SPA shell for the retired legacy HTML settings GET path instead of 404ing" do
        get "/settings/edit/legacy"

        expect(response).to be_successful
        expect(response.body).to include('id="syrus-spa-root"')
      end
    end
  end
end
