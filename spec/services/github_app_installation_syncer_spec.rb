require "rails_helper"

RSpec.describe GithubAppInstallationSyncer do
  let(:admin) { Factories.user }
  let(:client) { class_double(GithubAppClient) }

  before do
    AppSetting.current.update!(github_app_id: 42, github_app_private_key_pem: OpenSSL::PKey::RSA.generate(2048).to_pem)
  end

  it "upserts installations and links matching repositories" do
    repo = Factories.repository(user: admin, owner: "acme")
    allow(client).to receive(:installations).and_return([
      installation_payload(id: 1001, login: "acme", account_id: 2001)
    ])

    described_class.new(client: client, default_user: admin).sync

    installation = Installation.find_by!(github_installation_id: 1001)
    expect(installation.account_login).to eq("acme")
    expect(installation.removed_at).to be_nil
    expect(repo.reload.installation).to eq(installation)
    expect(AppSetting.current).to have_attributes(
      github_app_installation_sync_succeeded_at: be_present,
      github_app_installation_sync_records_seen: 1,
      github_app_installation_sync_error_class: nil,
      github_app_installation_sync_error_message: nil
    )
  end

  it "records failed sync diagnostics before reraising" do
    allow(client).to receive(:installations).and_raise(Octokit::Unauthorized.new)

    expect {
      described_class.new(client: client, default_user: admin).sync
    }.to raise_error(Octokit::Unauthorized)

    expect(AppSetting.current).to have_attributes(
      github_app_installation_sync_started_at: be_present,
      github_app_installation_sync_error_class: "Octokit::Unauthorized"
    )
  end

  it "marks missing installations removed and unlinks repositories" do
    installation = Installation.create!(
      user: admin,
      github_installation_id: 1001,
      account_login: "acme",
      account_id: 2001,
      account_type: "Organization",
      installed_at: 1.day.ago
    )
    repo = Factories.repository(user: admin, owner: "acme", installation: installation)
    allow(client).to receive(:installations).and_return([])

    freeze_time do
      described_class.new(client: client, default_user: admin).sync
      expect(installation.reload.removed_at).to eq(Time.current)
      expect(repo.reload.installation).to be_nil
    end
  end

  it "no-ops when the app is not registered" do
    AppSetting.current.update!(github_app_id: nil)
    expect(client).not_to receive(:installations)

    described_class.new(client: client, default_user: admin).sync
  end

  def installation_payload(id:, login:, account_id:)
    {
      id: id,
      account: { login: login, id: account_id, type: "Organization" },
      created_at: "2026-05-11T12:00:00Z"
    }
  end
end
