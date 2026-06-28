require "rails_helper"

RSpec.describe "SPA shell", type: :request do
  it "uses the normal HTML authentication flow when signed out" do
    Factories.user

    get app_shell_path

    expect(response).to redirect_to(new_session_path)
  end

  it "serves the public root through the SPA shell when signed out" do
    Factories.user

    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
    expect(response.body).to include('"current_user":null')
  end

  it "serves the authenticated app shell at root when signed in" do
    user = Factories.user(email_address: "root-operator@example.com")
    sign_in_as(user)

    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
    expect(response.body).to include("root-operator@example.com")
    expect(response.body).not_to include('"current_user":null')
  end

  it "serves public auth routes through the SPA shell" do
    Factories.user

    [ new_session_path, new_password_path ].each do |path|
      get path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="syrus-spa-root"')
      expect(response.body).to include('"current_user":null')
      expect(response.body).not_to include("&quot;current_user&quot;")
    end
  end

  it "serves password reset routes through the SPA shell" do
    user = Factories.user

    get edit_password_path(user.password_reset_token)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
  end

  it "renders the React mount for signed-in users" do
    user = Factories.user
    sign_in_as(user)

    get app_shell_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
    expect(response.body).to include('id="syrus-bootstrap-data"')
    expect(response.body).to include(user.email_address)
    expect(response.body).to include("<title>Syrus</title>")
  end

  it "advertises the branded favicon and PWA manifest assets" do
    user = Factories.user
    sign_in_as(user)

    get app_shell_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('<link rel="icon" href="/icon.png" type="image/png">')
    expect(response.body).to include('<link rel="icon" href="/icon.svg" type="image/svg+xml">')
    expect(response.body).to include('<link rel="apple-touch-icon" href="/icon-192.png">')
    expect(response.body).to include('<link rel="manifest" href="/manifest.json">')
  end

  it "serves PWA icon sizes from distinct branded assets" do
    get pwa_manifest_path

    expect(response).to have_http_status(:ok)
    manifest = JSON.parse(response.body)
    expect(manifest.fetch("icons")).to contain_exactly(
      include("src" => "/icon-192.png", "type" => "image/png", "sizes" => "192x192"),
      include("src" => "/icon-512.png", "type" => "image/png", "sizes" => "512x512", "purpose" => "maskable")
    )
    expect(manifest.fetch("theme_color")).to eq("#c9704b")
    expect(manifest.fetch("background_color")).to eq("#f7ead5")
  end

  it "serves nested React routes through the SPA shell" do
    user = Factories.user
    sign_in_as(user)

    get "/app-shell/admin"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
  end

  it "serves canonical dashboard routes through the SPA shell" do
    user = Factories.user
    sign_in_as(user)

    [ root_path, dashboard_path, dashboard_epics_path, dashboard_jobs_path, dashboard_workflows_path ].each do |path|
      get path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="syrus-spa-root"')
      expect(response.body).to include('id="syrus-bootstrap-data"')
    end
  end

  it "serves top-level app routes through the SPA shell" do
    user = Factories.user
    sign_in_as(user)

    [ notifications_path, memories_path, search_chats_path ].each do |path|
      get path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="syrus-spa-root"')
      expect(response.body).to include('id="syrus-bootstrap-data"')
    end
  end

  it "requires authentication for canonical dashboard routes" do
    Factories.user

    get dashboard_jobs_path

    expect(response).to redirect_to(new_session_path)
  end

  it "requires admin access for admin SPA routes" do
    Factories.user
    user = Factories.user
    sign_in_as(user)

    get "/app-shell/admin"

    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to match(/admin/i)
  end

  it "requires admin access for non-/admin admin SPA routes" do
    Factories.user
    user = Factories.user
    sign_in_as(user)

    [ "/app-shell/invitations", "/app-shell/settings/edit", "/app-shell/admin/github_app/register", "/app-shell/admin/github_app/confirm" ].each do |path|
      get path

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to match(/admin/i)
    end
  end
end
