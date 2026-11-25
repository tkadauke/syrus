require "rails_helper"

RSpec.describe Installation do
  it "encrypts cached installation tokens at rest" do
    installation = Installation.create!(
      user: Factories.user,
      github_installation_id: 123,
      account_login: "acme",
      account_id: 456,
      account_type: "Organization",
      installed_at: Time.current,
      cached_token: "installation-token"
    )

    raw = Installation.connection.select_value(
      "SELECT cached_token FROM installations WHERE id = #{installation.id}"
    )
    expect(raw).not_to include("installation-token")
    expect(installation.reload.cached_token).to eq("installation-token")
  end

  it "stores GitHub installation and account ids beyond 32-bit integer range" do
    installation = Installation.create!(
      user: Factories.user,
      github_installation_id: 9_876_543_210,
      account_login: "acme",
      account_id: 8_765_432_109,
      account_type: "Organization",
      installed_at: Time.current
    )

    expect(installation.reload.github_installation_id).to eq(9_876_543_210)
    expect(installation.account_id).to eq(8_765_432_109)
  end

  it "mints an uncached token restricted to one repository and requested permissions" do
    user = Factories.user
    installation = Factories.installation(user: user, github_installation_id: 987, account_login: "acme")
    repository = Factories.repository(user: user, owner: "acme", installation: installation, github_repository_id: 42)
    settings = AppSetting.current
    allow(AppSetting).to receive(:current).and_return(settings)
    allow(settings).to receive(:github_app_id).and_return("123")
    allow(settings).to receive(:github_app_private_key_pem).and_return("key")
    allow(GithubAppClient).to receive(:app_jwt).with(settings).and_return("jwt")
    request = stub_request(:post, "https://api.github.com/app/installations/987/access_tokens")
      .with(body: { repository_ids: [ 42 ], permissions: { contents: "write" } }.to_json)
      .to_return(status: 201, body: { token: "ghs_scoped", expires_at: 30.minutes.from_now.iso8601 }.to_json)

    grant = installation.scoped_token(repository: repository, permissions: { contents: "write" })

    expect(grant[:token]).to eq("ghs_scoped")
    expect(installation.reload.cached_token).to be_nil
    expect(request).to have_been_requested.once
  end
end
