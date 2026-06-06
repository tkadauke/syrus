require "rails_helper"

RSpec.describe "SPA shell", type: :request do
  def bootstrap_data
    json = response.body.match(%r{<script id="syrus-bootstrap-data" type="application/json">\s*(.*?)\s*</script>}m)[1]
    JSON.parse(json)
  end

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

  it "serves logged-out root with first-admin public state" do
    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
    expect(bootstrap_data).to include(
      "current_user" => nil,
      "team_user_count" => 0,
      "public" => include(
        "first_signup" => true,
        "signups_open" => false,
        "signup_path" => "/users/new",
        "sign_in_path" => "/session/new"
      )
    )
  end

  it "serves logged-out root with open-signup public state" do
    Factories.user(email_address: "operator@example.com")
    AppSetting.current.update!(signups_open: true)

    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
    expect(bootstrap_data).to include(
      "current_user" => nil,
      "team_user_count" => 0,
      "public" => include(
        "first_signup" => false,
        "signups_open" => true,
        "signup_path" => "/users/new",
        "sign_in_path" => "/session/new"
      )
    )
    expect(response.body).not_to include("operator@example.com")
  end

  it "serves logged-out root with invite-only public state" do
    admin = Factories.user(email_address: "operator@example.com")
    Invitation.create!(invited_by: admin, email_address: "guest@example.com")

    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
    expect(bootstrap_data).to include(
      "current_user" => nil,
      "team_user_count" => 0,
      "public" => include(
        "first_signup" => false,
        "signups_open" => false,
        "signup_path" => "/users/new",
        "sign_in_path" => "/session/new"
      )
    )
    expect(response.body).not_to include("operator@example.com")
    expect(response.body).not_to include("guest@example.com")
  end

  it "serves logged-out root with an invitation token without exposing invitation metadata" do
    admin = Factories.user(email_address: "operator@example.com")
    invitation = Invitation.create!(invited_by: admin, email_address: "guest@example.com")

    get root_path(token: invitation.token)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
    expect(bootstrap_data).to include(
      "current_user" => nil,
      "public" => include(
        "first_signup" => false,
        "signups_open" => false,
        "signup_path" => "/users/new",
        "sign_in_path" => "/session/new"
      )
    )
    expect(response.body).not_to include("operator@example.com")
    expect(response.body).not_to include("guest@example.com")
    expect(response.body).not_to include(invitation.token)
  end

  it "serves the authenticated app shell at root when signed in" do
    user = Factories.user(email_address: "root-operator@example.com")
    sign_in_as(user)

    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
    expect(response.body).to include("root-operator@example.com")
    expect(response.body).not_to include('"current_user":null')
    expect(bootstrap_data).to include(
      "current_user" => include(
        "id" => user.id,
        "email_address" => "root-operator@example.com"
      ),
      "team_user_count" => 1
    )
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

  it "requires authentication for canonical dashboard routes" do
    Factories.user

    [ dashboard_path, dashboard_jobs_path, new_job_path, repositories_path, edit_credentials_path ].each do |path|
      get path

      expect(response).to redirect_to(new_session_path)
    end
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
