require "rails_helper"

RSpec.describe "Admin GitHub App registration", type: :request do
  let(:admin) { Factories.user }
  let(:pem) { OpenSSL::PKey::RSA.generate(2048).to_pem }

  before { sign_in_as(admin) }

  it "renders a GitHub manifest registration form" do
    get "/admin/github_app/register"

    expect(response).to be_successful
    expect(response.body).to include("GitHub App registration")
    expect(response.body).to include("https://github.com/settings/apps/new?state=")
    expect(response.body).to include("&quot;issues&quot;:&quot;write&quot;")
    expect(response.body).to include("&quot;pull_requests&quot;:&quot;write&quot;")
    expect(response.body).to include("&quot;metadata&quot;:&quot;read&quot;")

    form = Nokogiri::HTML(response.body).at_css("form[action^='https://github.com/settings/apps/new']")
    expect(form["target"]).to eq("_blank")
    expect(form["rel"]).to eq("noopener")
    expect(form.at_css("input[type='submit']")["formtarget"]).to eq("_blank")
  end

  it "exchanges the manifest code and persists encrypted credentials" do
    get "/admin/github_app/register"
    state = response.body.match(%r{settings/apps/new\?state=([^"]+)})[1]
    stub_request(:post, "https://api.github.com/app-manifests/temp-code/conversions")
      .to_return(
        status: 201,
        headers: { "Content-Type" => "application/json" },
        body: {
          id: 12345,
          slug: "operator-syrus",
          pem: pem,
          webhook_secret: "secret-from-github"
        }.to_json
      )

    expect {
      get "/admin/github_app/callback", params: { code: "temp-code", state: state }
    }.to have_enqueued_job(SyncInstallationsJob).with(admin.id)

    settings = AppSetting.current.reload
    expect(settings.github_app_id).to eq(12345)
    expect(settings.github_app_slug).to eq("operator-syrus")
    expect(settings.github_app_private_key_pem).to eq(pem)
    expect(settings.github_app_webhook_secret).to eq("secret-from-github")
    expect(settings.github_app_registered_at).to be_present
    expect(response).to redirect_to(admin_github_app_confirm_path)
  end

  it "rejects callbacks with a mismatched state" do
    get "/admin/github_app/register"

    expect {
      get "/admin/github_app/callback", params: { code: "temp-code", state: "wrong" }
    }.not_to change { AppSetting.current.reload.github_app_id }
    expect(response).to redirect_to(admin_github_app_register_path)
  end

  it "returns 200 for the declared webhook stub" do
    post "/github_app/webhook"
    expect(response).to have_http_status(:ok)
  end

  it "records approval metadata from pull_request_review webhooks" do
    repository = Factories.repository(user: admin, owner: "acme", name: "widgets")
    job = Factories.job(repository: repository, issue_number: 42, pr_number: 7)
    job.update!(state: "implemented")

    payload = {
      review: {
        state: "approved",
        submitted_at: "2026-05-16T00:15:00Z",
        html_url: "https://github.com/acme/widgets/pull/7#pullrequestreview-99"
      },
      repository: {
        name: "widgets",
        owner: { login: "acme" }
      },
      pull_request: {
        number: 7
      }
    }

    post "/github_app/webhook",
         params: payload.to_json,
         headers: { "CONTENT_TYPE" => "application/json", "X-GitHub-Event" => "pull_request_review" }

    expect(response).to have_http_status(:ok)
    expect(job.reload.state).to eq("approved")
    expect(job.approved_at).to eq(Time.zone.parse("2026-05-16T00:15:00Z"))
    expect(job.approved_via).to eq("github_review")
    expect(job.approval_evidence).to eq("github_review_url" => "https://github.com/acme/widgets/pull/7#pullrequestreview-99")
  end
end
