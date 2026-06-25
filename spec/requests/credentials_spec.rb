require "rails_helper"

RSpec.describe "Credentials", type: :request do
  let(:user) { Factories.user }

  it "requires authentication" do
    user

    get edit_credentials_path

    expect(response).to redirect_to(new_session_path)
  end

  context "signed in" do
    before { sign_in_as(user) }

    it "serves the React credentials shell" do
      get edit_credentials_path

      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end

    it "serves the React credentials shell from the settings alias" do
      get settings_path

      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end

    it "serves the React personal documents shell" do
      get "/documents"

      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end

    it "serves the React notification settings shell" do
      get notification_settings_path

      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end

    it "does not route the retired legacy HTML credential endpoints" do
      expect {
        Rails.application.routes.recognize_path("/credentials/edit/legacy", method: :get)
      }.to raise_error(ActionController::RoutingError)
      expect {
        Rails.application.routes.recognize_path("/credentials", method: :patch)
      }.to raise_error(ActionController::RoutingError)
      expect {
        Rails.application.routes.recognize_path("/credentials/legacy", method: :patch)
      }.to raise_error(ActionController::RoutingError)
      expect {
        Rails.application.routes.recognize_path("/credentials/rotate_api_token", method: :post)
      }.to raise_error(ActionController::RoutingError)
      expect {
        Rails.application.routes.recognize_path("/credentials/revoke_api_token", method: :delete)
      }.to raise_error(ActionController::RoutingError)
    end
  end
end
