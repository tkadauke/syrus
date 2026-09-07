require "rails_helper"

RSpec.describe "Admin stuck list", type: :request do
  let(:admin) { Factories.user }
  let(:non_admin) do
    admin
    Factories.user
  end

  describe "GET /admin/stuck" do
    it "blocks non-admins" do
      sign_in_as(non_admin)
      get "/admin/stuck"
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to match(/admin/i)
    end

    it "serves the React stuck-items shell for admins" do
      sign_in_as(admin)
      get "/admin/stuck"
      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end

  it "serves the SPA shell for the retired legacy stuck-items GET path instead of 404ing" do
    sign_in_as(admin)
    get "/admin/stuck/legacy"

    expect(response).to be_successful
    expect(response.body).to include('id="syrus-spa-root"')
  end
end
