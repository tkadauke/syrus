require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/github_app", type: :request do
  let!(:admin) { Factories.user }
  let(:non_admin) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/admin/github_app/register"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/github_app/register"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "returns the manifest registration payload and stores callback state" do
    admin.update!(locale: "de")
    sign_in_as(admin)

    get "/api/v1/app/admin/github_app/register", params: { origin: "onboarding" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.fetch("submit_label")).to eq("GitHub App registrieren")
    expect(body.dig("github_app", "registered")).to be false

    bounce = URI.parse(body.fetch("bounce_url"))
    expect(bounce.path).to eq("/admin/github_app/manifest")
    query = Rack::Utils.parse_query(bounce.query)
    # The desktop shell keys off this marker to open the bounce page in the
    # user's default browser instead of the embedded window.
    expect(query.fetch("syrus_external")).to eq("1")

    payload = GithubAppManifestState.verify(query.fetch("state"))
    expect(payload.user_id).to eq(admin.id)
    expect(payload.origin).to eq("onboarding")

    # The manifest itself is now rendered by the bounce page, from the same
    # template the register payload used to inline.
    manifest = GithubAppManifest.new(user: admin, callback_url: "http://example.test/admin/github_app/callback").manifest
    expect(manifest.dig("default_permissions", "issues")).to eq("write")
    expect(manifest.dig("default_permissions", "pull_requests")).to eq("write")
    expect(manifest.dig("default_permissions", "metadata")).to eq("read")
    expect(manifest).not_to have_key("hook_attributes")
    expect(manifest.to_json).not_to include("github_app/webhook")
  end

  it "returns stored registration status for the confirmation page" do
    sign_in_as(admin)
    AppSetting.current.update!(
      github_app_id: 12345,
      github_app_slug: "operator-syrus",
      github_app_registered_at: Time.zone.parse("2026-05-30 12:00:00")
    )

    get "/api/v1/app/admin/github_app/confirm"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("github_app")).to include(
      "registered" => true,
      "id" => 12345,
      "slug" => "operator-syrus",
      "registered_at" => "2026-05-30T12:00:00Z",
      "install_url" => "https://github.com/apps/operator-syrus/installations/new"
    )
  end

  it "lists active installations so setup can flip to installed the moment a sync links one" do
    sign_in_as(admin)
    AppSetting.current.update!(github_app_id: 12345, github_app_slug: "operator-syrus")
    Factories.installation(account_login: "octocat", account_type: "User")
    Factories.installation(account_login: "gone-org", removed_at: Time.current)

    get "/api/v1/app/admin/github_app/confirm"

    expect(parse_body.dig("github_app", "installations")).to eq(
      [{ "account_login" => "octocat", "account_type" => "User" }]
    )
  end

  it "enqueues an installation sync on demand, throttled" do
    memory_cache = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(memory_cache)
    sign_in_as(admin)

    expect {
      post "/api/v1/app/admin/github_app/sync_installations"
    }.to have_enqueued_job(SyncInstallationsJob).with(admin.id)
    expect(parse_body).to eq("enqueued" => true)

    # A 3-second UI poll must not stack sync jobs — the cache throttle
    # swallows repeats inside the window.
    expect {
      post "/api/v1/app/admin/github_app/sync_installations"
    }.not_to have_enqueued_job(SyncInstallationsJob)
    expect(parse_body).to eq("enqueued" => false)
  end
end
