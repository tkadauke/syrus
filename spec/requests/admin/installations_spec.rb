require "rails_helper"

RSpec.describe "Admin installations health", type: :request do
  let(:admin) { Factories.user }

  before { sign_in_as(admin) }

  it "serves the React installations shell" do
    get admin_installations_path

    expect(response).to be_successful
    expect(response.body).to include('id="syrus-spa-root"')
  end

  it "serves the SPA shell for the retired legacy HTML installation GET path instead of 404ing" do
    get "/admin/installations/legacy"

    expect(response).to be_successful
    expect(response.body).to include('id="syrus-spa-root"')
  end

  it "does not route the retired legacy HTML installation endpoints" do
    expect {
      Rails.application.routes.recognize_path("/admin/installations/refresh", method: :post)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/admin/installations/legacy/refresh", method: :post)
    }.to raise_error(ActionController::RoutingError)
  end
end
