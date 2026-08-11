require "rails_helper"

RSpec.describe "SPA: /admin/tailscale", type: :request do
  it "serves the admin tailscale route through the SPA shell for admins" do
    user = Factories.user(admin: true)
    sign_in_as(user)

    get "/admin/tailscale"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
    expect(response.body).to include('id="syrus-bootstrap-data"')
  end

  it "redirects non-admin users" do
    Factories.user
    user = Factories.user
    sign_in_as(user)

    get "/admin/tailscale"

    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to match(/admin/i)
  end
end
