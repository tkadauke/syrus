require "rails_helper"

RSpec.describe "Admin GitHub App registration", type: :request do
  let(:admin) { Factories.user }
  let(:pem) { OpenSSL::PKey::RSA.generate(2048).to_pem }

  before { sign_in_as(admin) }

  def register_state(origin: nil)
    get "/api/v1/app/admin/github_app/register", params: origin ? { origin: origin } : {}
    bounce = JSON.parse(response.body).fetch("bounce_url")
    Rack::Utils.parse_query(URI.parse(bounce).query).fetch("state")
  end

  def stub_conversion(id: 12345)
    stub_request(:post, "https://api.github.com/app-manifests/temp-code/conversions")
      .to_return(
        status: 201,
        headers: { "Content-Type" => "application/json" },
        body: { id: id, slug: "operator-syrus", pem: pem }.to_json
      )
  end

  it "serves GitHub App pages through the React shell" do
    get "/admin/github_app/register"

    expect(response).to be_successful
    expect(response.body).to include('id="syrus-spa-root"')
    expect(response.body).not_to include("https://github.com/settings/apps/new?state=")

    get "/admin/github_app/confirm"

    expect(response).to be_successful
    expect(response.body).to include('id="syrus-spa-root"')
  end

  it "serves the manifest bounce page without a session" do
    admin.update!(locale: "de")
    state = register_state

    reset!
    get "/admin/github_app/manifest", params: { state: state }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(%(action="https://github.com/settings/apps/new?state=#{CGI.escape(state)}"))
    expect(response.body).to include("Weiter zu GitHub")
    expect(response.body).to include('name="manifest"')
    expect(response.body).to include("document.forms[0].submit()")
    expect(response.body).not_to include('id="syrus-spa-root"')
  end

  it "rejects the bounce page for forged or expired states" do
    get "/admin/github_app/manifest", params: { state: "forged" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("invalid or has expired")

    state = register_state
    travel (GithubAppManifestState::TTL + 1.minute) do
      get "/admin/github_app/manifest", params: { state: state }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  it "exchanges the manifest code and persists encrypted credentials without a session" do
    admin.update!(locale: "de")
    state = register_state
    stub_conversion

    reset!
    expect {
      get "/admin/github_app/callback", params: { code: "temp-code", state: state }
    }.to have_enqueued_job(SyncInstallationsJob).with(admin.id)

    settings = AppSetting.current.reload
    expect(settings.github_app_id).to eq(12345)
    expect(settings.github_app_slug).to eq("operator-syrus")
    expect(settings.github_app_private_key_pem).to eq(pem)
    expect(settings.github_app_registered_at).to be_present
    expect(response).to redirect_to(admin_github_app_confirm_path)
    expect(flash[:notice]).to eq("GitHub App registriert")
  end

  it "renders a minimal close-me page (not the admin redirect) for the onboarding origin" do
    admin.update!(locale: "la")
    state = register_state(origin: "onboarding")
    stub_conversion(id: 99)

    reset!
    get "/admin/github_app/callback", params: { code: "temp-code", state: state }

    expect(response).to have_http_status(:ok)
    expect(response).not_to redirect_to(admin_github_app_confirm_path)
    expect(response.body).to include("GitHub App relata est")
    expect(response.body).to include("Hanc fenestram claudere potes")
    expect(response.body).not_to include('id="syrus-spa-root"')
    expect(AppSetting.current.reload.github_app_id).to eq(99)
  end

  it "rejects callbacks with a mismatched state" do
    register_state

    expect {
      get "/admin/github_app/callback", params: { code: "temp-code", state: "wrong" }
    }.not_to change { AppSetting.current.reload.github_app_id }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("invalid or has expired")
  end

  it "rejects a replayed state (single-use nonce)" do
    memory_cache = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(memory_cache)

    state = register_state
    stub_conversion

    get "/admin/github_app/callback", params: { code: "temp-code", state: state }
    expect(response).to redirect_to(admin_github_app_confirm_path)

    get "/admin/github_app/callback", params: { code: "temp-code", state: state }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("invalid or has expired")
  end

  it "renders the failure page when GitHub returns no manifest code" do
    admin.update!(locale: "de")
    state = register_state

    get "/admin/github_app/callback", params: { state: state }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("GitHub hat keinen Manifest-Code zurückgegeben.")
  end

  it "does not expose a GitHub App webhook route" do
    post "/github_app/webhook"

    expect(response).to have_http_status(:not_found)
  end
end
