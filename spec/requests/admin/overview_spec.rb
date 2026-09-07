require "rails_helper"

RSpec.describe "Admin overview", type: :request do
  let(:admin) { Factories.user }
  let(:non_admin) do
    admin
    Factories.user
  end

  describe "GET /admin" do
    it "redirects unauthenticated users" do
      get "/admin"
      expect(response).to redirect_to(new_session_path).or redirect_to(new_user_path)
    end

    it "blocks non-admins" do
      sign_in_as(non_admin)
      get "/admin"
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to match(/admin/i)
    end

    it "renders the overview for admins" do
      sign_in_as(admin)
      get "/admin"
      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
      expect(response.body).to include("<title>Syrus</title>")
    end
  end

  it "serves the SPA shell for the retired legacy overview GET path instead of 404ing" do
    sign_in_as(admin)
    get "/admin/legacy"

    expect(response).to be_successful
    expect(response.body).to include('id="syrus-spa-root"')
  end
end
